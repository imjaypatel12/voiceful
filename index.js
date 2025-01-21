const express = require('express');
const { WebSocketServer } = require('ws');
const app = express();

app.use(express.json());

// Serve static client files
app.use(express.static('public'));

// In-memory store of client sockets keyed by user/clientId
const clientMap = {};

// Create an HTTP server and attach WebSocket server
const server = app.listen(3000, () => {
  console.log('Server listening on port 3000');
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  let userId = null;

  // On message, expect either registration or broadcast
  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      if (msg.type === 'registration' && msg.userId) {
        // register client
        userId = msg.userId;
        clientMap[userId] = ws;
        console.log(`User ${userId} registered`);
      } else if (msg.type === 'broadcast') {
        // Send to all connected clients
        wss.clients.forEach((client) => {
          if (client.readyState === 1) {
            client.send(JSON.stringify({
              from: userId,
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
    if (userId && clientMap[userId]) {
      delete clientMap[userId];
      console.log(`User ${userId} disconnected`);
    }
  });
});

// A simple REST endpoint to notify a client
app.post('/notify', (req, res) => {
  // Expects JSON with { userId, message }
  const { userId, message } = req.body;
  const ws = clientMap[userId];
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
  return res.status(404).json({ error: 'User not found or not connected' });
});