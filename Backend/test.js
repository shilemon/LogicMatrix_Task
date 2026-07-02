// Minimal smoke test - no test framework dependency required.
// Starts the express app in-process and hits /health.
const http = require('http');
const app = require('./server');

const server = http.createServer(app);

server.listen(0, () => {
  const { port } = server.address();
  http.get(`http://127.0.0.1:${port}/health`, (res) => {
    let data = '';
    res.on('data', (chunk) => (data += chunk));
    res.on('end', () => {
      const body = JSON.parse(data);
      if (res.statusCode === 200 && body.status === 'ok') {
        console.log('PASS: /health returned ok');
        server.close();
        process.exit(0);
      } else {
        console.error('FAIL: unexpected response', res.statusCode, body);
        server.close();
        process.exit(1);
      }
    });
  }).on('error', (err) => {
    console.error('FAIL: request error', err);
    process.exit(1);
  });
});
