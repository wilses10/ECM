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
