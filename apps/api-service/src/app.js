import express from 'express';

export function createApp() {
  const app = express();
  app.use(express.json());

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok' });
  });

  app.get('/greet/:name', (req, res) => {
    res.json({ message: `Hello, ${req.params.name}!` });
  });

  app.post('/sum', (req, res) => {
    const { a = 0, b = 0 } = req.body || {};
    res.json({ sum: Number(a) + Number(b) });
  });

  return app;
}
