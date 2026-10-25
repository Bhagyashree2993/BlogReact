// API tests run without a real database: the mysql pool is mocked.
jest.mock('../src/config/db', () => ({
  pool: { query: jest.fn() },
  checkDbConnection: jest.fn(),
}));

process.env.JWT_SECRET = 'test-secret';

const request = require('supertest');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const { pool, checkDbConnection } = require('../src/config/db');
const app = require('../src/server');

const token = jwt.sign({ id: 1, name: 'Tester', email: 't@example.com' }, 'test-secret');

beforeEach(() => jest.clearAllMocks());

describe('health & metrics', () => {
  test('GET /healthz returns ok', async () => {
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  test('GET /readyz returns 200 when DB is reachable', async () => {
    checkDbConnection.mockResolvedValue(true);
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(200);
  });

  test('GET /readyz returns 503 when DB is down', async () => {
    checkDbConnection.mockRejectedValue(new Error('ECONNREFUSED'));
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(503);
  });

  test('GET /metrics exposes Prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_request_duration_seconds');
  });

  test('unknown route returns 404', async () => {
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
  });
});

describe('auth', () => {
  test('register validates input', async () => {
    const res = await request(app).post('/api/auth/register').send({ name: 'a', email: 'bad', password: '1' });
    expect(res.status).toBe(400);
  });

  test('register rejects duplicate email', async () => {
    pool.query.mockResolvedValueOnce([[{ id: 9 }]]);
    const res = await request(app)
      .post('/api/auth/register')
      .send({ name: 'Ann', email: 'ann@example.com', password: 'longpassword' });
    expect(res.status).toBe(409);
  });

  test('register creates user and returns token', async () => {
    pool.query.mockResolvedValueOnce([[]]).mockResolvedValueOnce([{ insertId: 5 }]);
    const res = await request(app)
      .post('/api/auth/register')
      .send({ name: 'Ann', email: 'ann@example.com', password: 'longpassword' });
    expect(res.status).toBe(201);
    expect(res.body.token).toBeDefined();
    expect(res.body.user.id).toBe(5);
  });

  test('login succeeds with correct password', async () => {
    const hash = await bcrypt.hash('longpassword', 4);
    pool.query.mockResolvedValueOnce([[{ id: 1, name: 'Ann', email: 'ann@example.com', password_hash: hash }]]);
    const res = await request(app).post('/api/auth/login').send({ email: 'ann@example.com', password: 'longpassword' });
    expect(res.status).toBe(200);
    expect(res.body.token).toBeDefined();
  });

  test('login fails with wrong password', async () => {
    const hash = await bcrypt.hash('longpassword', 4);
    pool.query.mockResolvedValueOnce([[{ id: 1, name: 'Ann', email: 'ann@example.com', password_hash: hash }]]);
    const res = await request(app).post('/api/auth/login').send({ email: 'ann@example.com', password: 'wrongpass' });
    expect(res.status).toBe(401);
  });
});

describe('posts', () => {
  test('lists posts with pagination', async () => {
    pool.query.mockResolvedValueOnce([[{ id: 1, title: 'Hello' }]]).mockResolvedValueOnce([[{ total: 1 }]]);
    const res = await request(app).get('/api/posts?page=1&limit=5');
    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(1);
    expect(res.body.totalPages).toBe(1);
  });

  test('returns 404 for missing post', async () => {
    pool.query.mockResolvedValueOnce([[]]);
    const res = await request(app).get('/api/posts/missing');
    expect(res.status).toBe(404);
  });

  test('returns post with comments', async () => {
    pool.query.mockResolvedValueOnce([[{ id: 1, slug: 'x' }]]).mockResolvedValueOnce([[{ id: 2, body: 'hi' }]]);
    const res = await request(app).get('/api/posts/x');
    expect(res.status).toBe(200);
    expect(res.body.comments).toHaveLength(1);
  });

  test('creating a post requires auth', async () => {
    const res = await request(app).post('/api/posts').send({ title: 'Title', body: 'x'.repeat(30) });
    expect(res.status).toBe(401);
  });

  test('creates a post when authenticated', async () => {
    pool.query.mockResolvedValueOnce([{ insertId: 7 }]);
    const res = await request(app)
      .post('/api/posts')
      .set('Authorization', `Bearer ${token}`)
      .send({ title: 'My First Post', body: 'word '.repeat(30) });
    expect(res.status).toBe(201);
    expect(res.body.slug).toMatch(/^my-first-post-/);
  });

  test('adds a comment when authenticated', async () => {
    pool.query.mockResolvedValueOnce([[{ id: 1 }]]).mockResolvedValueOnce([{}]);
    const res = await request(app)
      .post('/api/posts/x/comments')
      .set('Authorization', `Bearer ${token}`)
      .send({ body: 'Nice post' });
    expect(res.status).toBe(201);
  });

  test('returns 500 when DB fails', async () => {
    pool.query.mockRejectedValueOnce(new Error('boom'));
    const res = await request(app).get('/api/posts');
    expect(res.status).toBe(500);
  });
});
