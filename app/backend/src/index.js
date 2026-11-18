const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const { Pool } = require('pg');
const Minio = require('minio');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');
const winston = require('winston');
const client = require('prom-client');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(winston.format.timestamp(), winston.format.json()),
  transports: [new winston.transports.Console()]
});

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Durée des requêtes HTTP',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register]
});

const documentsTotal = new client.Counter({
  name: 'ecm_documents_total',
  help: 'Nombre total de documents uploadés',
  registers: [register]
});

const documentsUploaded = new client.Gauge({
  name: 'ecm_documents_active',
  help: 'Nombre de documents actifs',
  registers: [register]
});

const app = express();
const PORT = process.env.PORT || 3000;

app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(rateLimit({ windowMs: 15 * 60 * 1000, max: 100 }));

app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => end({ method: req.method, route: req.path, status_code: res.statusCode }));
  next();
});

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'ecmdb',
  user: process.env.DB_USER || 'ecmuser',
  password: process.env.DB_PASSWORD || 'ecmpassword',
});

const minioClient = new Minio.Client({
  endPoint: process.env.MINIO_ENDPOINT || 'localhost',
  port: parseInt(process.env.MINIO_PORT) || 9000,
  useSSL: false,
  accessKey: process.env.MINIO_ACCESS_KEY || 'minioadmin',
  secretKey: process.env.MINIO_SECRET_KEY || 'minioadmin',
});

const BUCKET_NAME = process.env.MINIO_BUCKET || 'ecm-documents';
const upload = multer({ storage: multer.memoryStorage() });

async function initDB() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS documents (
        id UUID PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        description TEXT,
        category VARCHAR(100),
        mime_type VARCHAR(100),
        size_bytes BIGINT,
        minio_path VARCHAR(500),
        tags TEXT[],
        created_at TIMESTAMP DEFAULT NOW(),
        updated_at TIMESTAMP DEFAULT NOW()
      )
    `);
    logger.info('Base de données initialisée');
  } catch (err) {
    logger.error('Erreur init DB', { error: err.message });
  }
}

async function initMinio() {
  try {
    const exists = await minioClient.bucketExists(BUCKET_NAME);
    if (!exists) {
      await minioClient.makeBucket(BUCKET_NAME);
      logger.info('Bucket MinIO créé : ' + BUCKET_NAME);
    }
  } catch (err) {
    logger.error('Erreur init MinIO', { error: err.message });
  }
}

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'ecm-backend', version: '1.0.0' });
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.post('/api/documents', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) return res.status(400).json({ error: 'Aucun fichier fourni' });
    const id = uuidv4();
    const minioPath = id + '/' + req.file.originalname;
    await minioClient.putObject(BUCKET_NAME, minioPath, req.file.buffer, req.file.size, { 'Content-Type': req.file.mimetype });
    const tags = req.body.tags ? req.body.tags.split(',') : [];
    await pool.query(
      'INSERT INTO documents (id, name, description, category, mime_type, size_bytes, minio_path, tags) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)',
      [id, req.file.originalname, req.body.description || '', req.body.category || 'general', req.file.mimetype, req.file.size, minioPath, tags]
    );
    documentsTotal.inc();
    logger.info('Document uploadé', { id, name: req.file.originalname });
    res.status(201).json({ id, name: req.file.originalname, message: 'Document uploadé avec succès' });
  } catch (err) {
    logger.error('Erreur upload', { error: err.message });
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/documents', async (req, res) => {
  try {
    const { category, search } = req.query;
    let query = 'SELECT id, name, description, category, mime_type, size_bytes, tags, created_at FROM documents';
    const params = [];
    if (category) { query += ' WHERE category = $1'; params.push(category); }
    else if (search) { query += ' WHERE name ILIKE $1 OR description ILIKE $1'; params.push('%' + search + '%'); }
    query += ' ORDER BY created_at DESC';
    const result = await pool.query(query, params);
    documentsUploaded.set(result.rows.length);
    res.json({ documents: result.rows, total: result.rows.length });
  } catch (err) {
    logger.error('Erreur liste', { error: err.message });
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/documents/:id/download', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM documents WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Document non trouvé' });
    const doc = result.rows[0];
    const stream = await minioClient.getObject(BUCKET_NAME, doc.minio_path);
    res.setHeader('Content-Disposition', 'attachment; filename="' + doc.name + '"');
    res.setHeader('Content-Type', doc.mime_type);
    stream.pipe(res);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.delete('/api/documents/:id', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM documents WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Document non trouvé' });
    const doc = result.rows[0];
    await minioClient.removeObject(BUCKET_NAME, doc.minio_path);
    await pool.query('DELETE FROM documents WHERE id = $1', [req.params.id]);
    logger.info('Document supprimé', { id: req.params.id });
    res.json({ message: 'Document supprimé' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, async () => {
  logger.info('ECM Backend démarré sur le port ' + PORT);
  await initDB();
  await initMinio();
});

module.exports = app;
