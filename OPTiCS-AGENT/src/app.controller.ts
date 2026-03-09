import { Controller, Get, Query } from '@nestjs/common';
import { AppService } from './app.service';
import { PrismaService } from './prisma.service';

@Controller()
export class AppController {
  constructor(
    private readonly appService: AppService,
    private readonly prismaService: PrismaService,
  ) {}

  @Get('/connect')
  async handleDisplayConnectionCode() {
    return this.appService.getConnectionCode();
  }

  @Get('/cpu-metrics')
  async getCpuMetrics(@Query('from') from?: string, @Query('to') to?: string) {
    const fromTime = from
      ? parseInt(from)
      : Date.now() - 7 * 24 * 60 * 60 * 1000;
    const toTime = to ? parseInt(to) : Date.now();

    const data = await this.prismaService.cpuUsage.findMany({
      where: {
        timestamp: {
          gte: fromTime,
          lte: toTime,
        },
      },
      orderBy: { timestamp: 'asc' },
      select: { timestamp: true, peak: true, average: true, min: true },
    });

    // BigInt를 Number로 변환
    return data.map((item) => ({
      timestamp: Number(item.timestamp),
      peak: item.peak,
      average: item.average,
      min: item.min,
    }));
  }

  @Get('/memory-metrics')
  async getMemoryMetrics(
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    const fromTime = from
      ? parseInt(from)
      : Date.now() - 7 * 24 * 60 * 60 * 1000;
    const toTime = to ? parseInt(to) : Date.now();

    const data = await this.prismaService.memoryUsage.findMany({
      where: {
        timestamp: {
          gte: fromTime,
          lte: toTime,
        },
      },
      orderBy: { timestamp: 'asc' },
      select: {
        timestamp: true,
        peak: true,
        average: true,
        min: true,
        totalMemory: true,
      },
    });

    // BigInt를 Number로 변환
    return data.map((item) => ({
      timestamp: Number(item.timestamp),
      peak: item.peak,
      average: item.average,
      min: item.min,
      totalMemory: item.totalMemory,
    }));
  }
}
