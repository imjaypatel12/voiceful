const express = require('express');
const { WebSocketServer } = require('ws');
const { exec } = require('child_process'); // Added child_process for executing system commands
const app = express();

app.use(express.json());

// Serve static client files
app.use(express.static('public'));

// In-memory store of client sockets keyed by clientId
const clientMap = {};

// Create an HTTP server and attach WebSocket server
const PORT = process.env.PORT || 3000;
const server = app.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  let clientId = null;

  // On message, expect either registration or broadcast
  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      if (msg.type === 'registration' && msg.clientId) {
        // register client
        clientId = msg.clientId;
        clientMap[clientId] = ws;
        console.log(`Client ${clientId} registered`);
      } else if (msg.type === 'broadcast') {
        // Send to all connected clients
        wss.clients.forEach((client) => {
          if (client.readyState === 1) {
            client.send(JSON.stringify({
              from: clientId,
              text: msg.text
            }));
          }
        });
      }
    } catch (err) {
      console.error('Error parsing message:', err);
    }
  });

  // If a client disconnects
  ws.on('close', () => {
    if (clientId && clientMap[clientId]) {
      delete clientMap[clientId];
      console.log(`Client ${clientId} disconnected`);
    }
  });
});

// A simple REST endpoint to notify a client
app.post('/notify', (req, res) => {
  // Expects JSON with { clientId, message }
  const { clientId, message } = req.body;
  const ws = clientMap[clientId];
  const defaultMessage = `New order received at: ${new Date().toLocaleString('en-US', { 
    month: '2-digit', 
    day: '2-digit', 
    year: 'numeric', 
    hour: '2-digit', 
    minute: '2-digit', 
    second: '2-digit', 
    hour12: true 
  })}`;
  const finalMessage = message || defaultMessage;
  
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify({
      from: 'Server',
      text: finalMessage
    }));
    return res.json({ success: true });
  }
  return res.status(404).json({ error: 'Client not found or not connected' });
});

// Endpoint to fetch connected clients
app.get('/clients', (req, res) => {
  const clients = Object.keys(clientMap);
  res.json({ clients });
});
