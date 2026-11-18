#!/bin/bash
set -e
echo "Création de tous les fichiers ECM..."

# ── kind/cluster-config.yaml ──
cat > kind/cluster-config.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ecm-cluster
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
  - role: worker
  - role: worker
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5001"]
          endpoint = ["http://kind-registry:5001"]
EOF

# ── kind/setup-cluster.sh ──
cat > kind/setup-cluster.sh << 'EOF'
#!/bin/bash
set -e
CLUSTER_NAME="ecm-cluster"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5001"

echo "============================================"
echo " ECM CI/CD - Setup Cluster Kind"
echo "============================================"

echo "[1/5] Registry locale..."
if [ "$(docker inspect -f '{{.State.Running}}' ${REGISTRY_NAME} 2>/dev/null)" != "true" ]; then
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge --name "${REGISTRY_NAME}" registry:2
  echo "  Registry démarrée sur localhost:${REGISTRY_PORT}"
else
  echo "  Registry déjà active"
fi

echo "[2/5] Cluster Kind..."
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "  Cluster ${CLUSTER_NAME} existe déjà"
else
  kind create cluster --config kind/cluster-config.yaml
fi

echo "[3/5] Connexion registry au réseau Kind..."
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' ${REGISTRY_NAME})" = 'null' ]; then
  docker network connect kind ${REGISTRY_NAME}
fi

echo "[4/5] ConfigMap registry..."
kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
YAML

echo "[5/5] Ingress NGINX..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

echo "============================================"
echo " Cluster ECM prêt !"
echo " Registry : localhost:${REGISTRY_PORT}"
echo " Ingress  : http://localhost:8080"
echo "============================================"
EOF

# ── app/backend/package.json ──
cat > app/backend/package.json << 'EOF'
{
  "name": "ecm-backend",
  "version": "1.0.0",
  "description": "ECM - Enterprise Content Management API",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "nodemon src/index.js",
    "test": "jest --forceExit --coverage"
  },
  "dependencies": {
    "express": "^4.18.2",
    "pg": "^8.11.3",
    "minio": "^7.1.3",
    "multer": "^1.4.5-lts.1",
    "uuid": "^9.0.0",
    "cors": "^2.8.5",
    "helmet": "^7.1.0",
    "express-rate-limit": "^7.1.5",
    "winston": "^3.11.0",
    "prom-client": "^15.1.0"
  },
  "devDependencies": {
    "jest": "^29.7.0",
    "supertest": "^6.3.4",
    "nodemon": "^3.0.2"
  }
}
EOF

# ── app/backend/Dockerfile ──
cat > app/backend/Dockerfile << 'EOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine AS production
RUN addgroup -g 1001 -S ecm && adduser -S -u 1001 -G ecm ecm
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --chown=ecm:ecm src/ ./src/
COPY --chown=ecm:ecm package.json ./
USER ecm
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/index.js"]
EOF

# ── app/backend/src/index.js ──
cat > app/backend/src/index.js << 'EOF'
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
EOF

# ── app/backend/src/index.test.js ──
cat > app/backend/src/index.test.js << 'EOF'
const request = require('supertest');
const app = require('./index');

describe('ECM Backend API', () => {
  describe('GET /health', () => {
    it('retourne status ok', async () => {
      const res = await request(app).get('/health');
      expect(res.statusCode).toBe(200);
      expect(res.body.status).toBe('ok');
      expect(res.body.service).toBe('ecm-backend');
    });
  });
  describe('GET /metrics', () => {
    it('retourne les métriques Prometheus', async () => {
      const res = await request(app).get('/metrics');
      expect(res.statusCode).toBe(200);
      expect(res.text).toContain('http_request_duration_seconds');
    });
  });
  describe('POST /api/documents', () => {
    it('retourne 400 sans fichier', async () => {
      const res = await request(app).post('/api/documents').field('description', 'test');
      expect(res.statusCode).toBe(400);
      expect(res.body.error).toBe('Aucun fichier fourni');
    });
  });
});
EOF

# ── k8s/namespace/namespace.yaml ──
cat > k8s/namespace/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ecm
  labels:
    app.kubernetes.io/name: ecm
    environment: production
EOF

# ── k8s/postgresql/postgresql.yaml ──
cat > k8s/postgresql/postgresql.yaml << 'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-pvc
  namespace: ecm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
  namespace: ecm
type: Opaque
stringData:
  POSTGRES_DB: ecmdb
  POSTGRES_USER: ecmuser
  POSTGRES_PASSWORD: ecmpassword
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  namespace: ecm
  labels:
    app: postgresql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
        - name: postgresql
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgresql-secret
          volumeMounts:
            - name: postgresql-data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "ecmuser", "-d", "ecmdb"]
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "ecmuser", "-d", "ecmdb"]
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: postgresql-data
          persistentVolumeClaim:
            claimName: postgresql-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: ecm
spec:
  selector:
    app: postgresql
  ports:
    - port: 5432
      targetPort: 5432
EOF

# ── k8s/minio/minio.yaml ──
cat > k8s/minio/minio.yaml << 'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: ecm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: ecm
type: Opaque
stringData:
  MINIO_ROOT_USER: minioadmin
  MINIO_ROOT_PASSWORD: minioadmin123
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ecm
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          command: ["minio", "server", "/data", "--console-address", ":9001"]
          ports:
            - containerPort: 9000
            - containerPort: 9001
          envFrom:
            - secretRef:
                name: minio-secret
          volumeMounts:
            - name: minio-data
              mountPath: /data
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: minio-data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ecm
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
EOF

# ── k8s/backend/backend.yaml ──
cat > k8s/backend/backend.yaml << 'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ecm-backend
  namespace: ecm
  labels:
    app: ecm-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ecm-backend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ecm-backend
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: ecm-backend
          image: localhost:5001/ecm-backend:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 3000
          env:
            - name: PORT
              value: "3000"
            - name: DB_HOST
              value: "postgresql"
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: postgresql-secret
                  key: POSTGRES_DB
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: postgresql-secret
                  key: POSTGRES_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql-secret
                  key: POSTGRES_PASSWORD
            - name: MINIO_ENDPOINT
              value: "minio"
            - name: MINIO_PORT
              value: "9000"
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: MINIO_ROOT_USER
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: MINIO_ROOT_PASSWORD
            - name: MINIO_BUCKET
              value: "ecm-documents"
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 15
---
apiVersion: v1
kind: Service
metadata:
  name: ecm-backend
  namespace: ecm
spec:
  selector:
    app: ecm-backend
  ports:
    - port: 3000
      targetPort: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ecm-ingress
  namespace: ecm
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx
  rules:
    - host: ecm.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ecm-backend
                port:
                  number: 3000
EOF

# ── .github/workflows/ci-cd.yaml ──
mkdir -p .github/workflows
cat > .github/workflows/ci-cd.yaml << 'EOF'
name: ECM CI/CD Pipeline

on:
  push:
    branches: [main, develop]
    paths:
      - 'app/**'
      - 'k8s/**'
  pull_request:
    branches: [main]
    paths:
      - 'app/**'

env:
  REGISTRY: localhost:5001
  IMAGE_NAME: ecm-backend

jobs:
  test:
    name: Tests & Lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: app/backend/package-lock.json
      - name: Installer les dépendances
        working-directory: app/backend
        run: npm ci
      - name: Lancer les tests
        working-directory: app/backend
        run: npm test
        env:
          NODE_ENV: test
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: coverage-report
          path: app/backend/coverage/

  build:
    name: Build & Push Docker
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main'
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}
    steps:
      - uses: actions/checkout@v4
      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=sha-
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v5
        with:
          context: app/backend
          file: app/backend/Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  update-manifests:
    name: Update GitOps Manifests
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
      - name: Mettre à jour le tag image
        run: |
          NEW_TAG="sha-$(echo ${{ github.sha }} | cut -c1-7)"
          sed -i "s|image: localhost:5001/ecm-backend:.*|image: localhost:5001/ecm-backend:${NEW_TAG}|g" k8s/backend/backend.yaml
          echo "Image mise à jour -> ${NEW_TAG}"
      - name: Commit manifests
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add k8s/backend/backend.yaml
          git diff --staged --quiet || git commit -m "chore: update image tag [skip ci]"
          git push
EOF

# ── setup-app.sh ──
cat > setup-app.sh << 'EOF'
#!/bin/bash
set -e
echo "============================================"
echo " ECM CI/CD - Déploiement Application"
echo "============================================"

echo "[1/5] Namespace..."
kubectl apply -f k8s/namespace/namespace.yaml

echo "[2/5] Build image Docker..."
docker build -t localhost:5001/ecm-backend:latest app/backend/
docker push localhost:5001/ecm-backend:latest

echo "[3/5] PostgreSQL..."
kubectl apply -f k8s/postgresql/postgresql.yaml
kubectl wait --namespace ecm --for=condition=ready pod --selector=app=postgresql --timeout=120s

echo "[4/5] MinIO..."
kubectl apply -f k8s/minio/minio.yaml
kubectl wait --namespace ecm --for=condition=ready pod --selector=app=minio --timeout=120s

echo "[5/5] ECM Backend..."
kubectl apply -f k8s/backend/backend.yaml
kubectl wait --namespace ecm --for=condition=ready pod --selector=app=ecm-backend --timeout=120s

echo ""
kubectl get pods -n ecm
echo ""
echo "============================================"
echo " Application ECM déployée !"
echo " Test : curl http://localhost:8080/health -H 'Host: ecm.local'"
echo "============================================"
EOF

# ── .gitignore ──
cat > .gitignore << 'EOF'
node_modules/
coverage/
.env
*.log
EOF

chmod +x kind/setup-cluster.sh setup-app.sh
echo ""
echo "Tous les fichiers créés !"