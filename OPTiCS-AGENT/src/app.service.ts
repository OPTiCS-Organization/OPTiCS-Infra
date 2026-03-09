import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Cron } from '@nestjs/schedule';
import log from 'spectra-log';
import { PrismaService } from './prisma.service.js';
import { InfoGateway } from './socket.gateway.js';
import os from 'os-utils';

@Injectable()
export class AppService implements OnApplicationBootstrap {
  private stack: number = 0;
  private cpuMax: number = 0;
  private cpuSum: number = 0;
  private cpuMin: number = Infinity;
  private memoryMax: number = 0;
  private memorySum: number = 0;
  private memoryMin: number = Infinity;

  constructor(
    private readonly configService: ConfigService,
    private readonly prismaService: PrismaService,
    private readonly infoGateway: InfoGateway,
  ) {}

  async onApplicationBootstrap() {
    const response = await fetch(
      this.configService.get<string>('CENTRAL_SERVER_URL') +
        '/server/initialize',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      },
    );

    // should add dto,
    const data = await response.json();
    log(data);

    await this.prismaService.agentInfo.upsert({
      where: {
        key: 'agent-code',
      },
      update: { value: data.data.connectionCode },
      create: { key: 'agent-code', value: data.data.connectionCode },
    });
  }

  async getConnectionCode() {
    return await this.prismaService.agentInfo.findFirst({
      where: {
        key: 'agent-code',
      },
    });
  }

  @Cron('* * * * * *')
  async heartbeat() {
    try {
      os.cpuUsage((usage) =>
        this.updatePerformance(usage * 100, os.totalmem() - os.freemem()),
      );
    } catch (error) {
      log(error, 500, 'ERROR');
    }
  }

  async updatePerformance(cpuUsage: number, memoryUsage: number) {
    this.stack++;
    if (this.stack >= 5) {
      const cpuData = {
        timestamp: Date.now(),
        peak: this.numberSlicer(this.cpuMax),
        average: this.numberSlicer(this.cpuSum / 5),
        min: this.numberSlicer(this.cpuMin),
      };

      // DB에 저장
      try {
        await this.prismaService.cpuUsage.create({
          data: cpuData,
        });

        // 7일 이상 된 데이터 삭제
        const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
        await this.prismaService.cpuUsage.deleteMany({
          where: { timestamp: { lt: sevenDaysAgo } },
        });
      } catch (error) {
        log(error, 500, 'ERROR');
      }

      // 메모리 데이터 저장 및 전송
      const memoryData = {
        timestamp: Date.now(),
        peak: this.memoryMax,
        average: this.memorySum / 5,
        min: this.memoryMin,
        totalMemory: os.totalmem(),
      };

      try {
        await this.prismaService.memoryUsage.create({
          data: memoryData,
        });

        // 7일 이상 된 데이터 삭제
        const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
        await this.prismaService.memoryUsage.deleteMany({
          where: { timestamp: { lt: sevenDaysAgo } },
        });
      } catch (error) {
        log(error, 500, 'ERROR');
      }

      const info = {
        cpu: cpuData,
        memory: memoryData,
      };

      // WebSocket으로 메모리 데이터 전송
      this.infoGateway.sendData(info);

      this.cpuMax = 0;
      this.cpuSum = 0;
      this.cpuMin = Infinity;

      this.memoryMax = 0;
      this.memorySum = 0;
      this.memoryMin = Infinity;

      this.stack = 0;
    }
    this.cpuMax = Math.max(this.cpuMax, cpuUsage);
    this.cpuSum += cpuUsage;
    this.cpuMin = Math.min(this.cpuMin, cpuUsage);

    this.memoryMax = Math.max(this.memoryMax, memoryUsage);
    this.memorySum += memoryUsage;
    this.memoryMin = Math.min(this.memoryMin, memoryUsage);
  }

  public numberSlicer(num: number) {
    const parts = num.toString().split('.');
    const integerPart = parseInt(parts[0]) || 0;
    const decimalPart = parts[1] ? parseFloat('0.' + parts[1].slice(0, 2)) : 0;
    return integerPart + decimalPart;
  }
}
