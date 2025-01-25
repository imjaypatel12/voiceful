const express = require('express');
const { WebSocketServer } = require('ws');
const escpos = require('escpos'); // Imported escpos library
escpos.USB = require('escpos-usb'); // Added escpos-usb for USB printer support
// const escposBluetooth = require('escpos-bluetooth'); // Removed escpos-bluetooth for Bluetooth printer support
const ping = require('net-ping'); // Added net-ping for Ethernet printer scanning
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

// New: API endpoint to list connected printers
app.get('/printers', async (req, res) => {
  try {
    const printers = [];
    
    // Retrieve subnet from query parameters or use default
    const subnet = req.query.subnet || '192.168.1.';

    // Validate subnet format
    if (!isValidSubnet(subnet)) {
      return res.status(400).json({ success: false, error: 'Invalid subnet format. Expected format: xxx.xxx.xxx.' });
    }

    // --- USB Printers ---
    const usbDevices = escpos.USB.findPrinter(); 
    usbDevices.forEach((device, index) => {
      printers.push({
        id: `usb-${index + 1}`,
        type: 'USB',
        deviceName: `${device.manufacturer} ${device.product}`,
        vendorId: device.deviceId.vendorId,
        productId: device.deviceId.productId
      });
    });

    // --- Ethernet Printers ---
    const ethernetPrinters = await findEthernetPrinters(subnet);
    ethernetPrinters.forEach((printer, index) => {
      printers.push({
        id: `ethernet-${index + 1}`,
        type: 'Ethernet',
        deviceName: printer.address,
        ipAddress: printer.address,
        port: printer.port
      });
    });

    res.json({ success: true, printers });
  } catch (error) {
    console.error('Error fetching printers:', error);
    res.status(500).json({ success: false, error: 'Failed to retrieve printers' });
  }
});

// New: REST API endpoint to print a message on a selected printer
app.post('/print', async (req, res) => {
  const { printer, message } = req.body;

  if (!printer || !message) {
    return res.status(400).json({ success: false, error: 'Printer and message are required.' });
  }

  try {
    // Initialize escpos device based on printer type
    let device;
    if (printer.type === 'USB') {
      device = new escpos.USB(printer.vendorId, printer.productId);
    } else if (printer.type === 'Ethernet') {
      device = new escpos.Network(printer.ipAddress, printer.port);
    } else {
      return res.status(400).json({ success: false, error: 'Unsupported printer type.' });
    }

    const options = { encoding: "GB18030" /* default */ };
    const printerEsc = new escpos.Printer(device, options);

    device.open(function(error){
      if (error) {
        console.error('Error opening printer:', error);
        return res.status(500).json({ success: false, error: 'Failed to open printer.' });
      }

      printerEsc
        .text(message)
        .cut()
        .close();

      console.log(`Printed message on printer: ${printer.deviceName}`);
      return res.json({ success: true });
    });
  } catch (err) {
    console.error('Error during printing:', err);
    return res.status(500).json({ success: false, error: 'Printing failed.' });
  }
});

// Function to find Ethernet Printers by scanning the provided subnet
function findEthernetPrinters(subnet) {
  return new Promise((resolve, reject) => {
    const session = ping.createSession();
    const printers = [];
    let pending = 0;

    for (let i = 1; i <= 254; i++) {
      const target = subnet + i;
      pending++;
      session.pingHost(target, { timeout: 200 }, (error, target) => {
        if (!error) {
          // Check if port 9100 is open
          const net = require('net');
          const socket = new net.Socket();
          socket.setTimeout(500);
          socket.on('connect', () => {
            printers.push({ address: target, port: 9100 });
            socket.destroy();
          }).on('timeout', () => {
            socket.destroy();
          }).on('error', () => {
            socket.destroy();
          }).on('close', () => {
            pending--;
            if (pending === 0) {
              resolve(printers);
            }
          });
          socket.connect(9100, target);
        } else {
          pending--;
          if (pending === 0) {
            resolve(printers);
          }
        }
      });
    }

    // Handle case where no printers are found
    setTimeout(() => {
      if (pending > 0) {
        resolve(printers);
      }
    }, 10000); // 10 seconds timeout
  });
}

// Function to validate subnet format
function isValidSubnet(subnet) {
  const subnetPattern = /^(\d{1,3}\.){3}$/;
  return subnetPattern.test(subnet);
}