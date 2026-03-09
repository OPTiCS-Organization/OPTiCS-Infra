import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { Injectable } from '@nestjs/common';
import log from 'spectra-log';

interface CpuData {
  timestamp: number;
  peak: number;
  average: number;
  min: number;
}

interface MemoryData {
  timestamp: number;
  peak: number;
  average: number;
  min: number;
  totalMemory: number;
}

@Injectable()
@WebSocketGateway({
  cors: {
    origin: 'http://localhost:5173',
    credentials: true,
  },
  namespace: '/info',
})
export class InfoGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  handleConnection(client: Socket) {
    log(`Client connected: ${client.id}`);
  }

  handleDisconnect(client: Socket) {
    log(`Client disconnected: ${client.id}`);
  }

  sendData(data: { cpu: CpuData; memory: MemoryData }) {
    this.server.emit('info', data);
  }
}
