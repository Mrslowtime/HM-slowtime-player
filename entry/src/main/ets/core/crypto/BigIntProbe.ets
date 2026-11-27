/**
 * 编译期探针：验证 ArkTS 严格模式是否支持 BigInt。
 * 仅用于早期编译验证，现已无调用方（原 MusicApi 的 M2D3_PROBE 调试分支已删除）；
 * 保留文件仅作备查，勿在新代码中引用。
 */
export function bigIntProbe(): string {
  const a: bigint = BigInt('0x123456789abcdef0');
  const b: bigint = BigInt(2654435769);
  const c: bigint = (a ^ b) & BigInt('0xffffffff');
  return c.toString(16);
}
