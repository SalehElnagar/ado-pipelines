import request from 'supertest';
import { createApp } from './app.js';

describe('api-service', () => {
  const app = createApp();

  it('returns health', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  it('greets a user', async () => {
    const res = await request(app).get('/greet/Azure');
    expect(res.body.message).toBe('Hello, Azure!');
  });

  it('sums two numbers', async () => {
    const res = await request(app).post('/sum').send({ a: 2, b: 3 });
    expect(res.body.sum).toBe(5);
  });
});
