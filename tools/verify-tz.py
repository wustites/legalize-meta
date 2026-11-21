"""校验 manifest 声明的时区是否等于该日「当地 0 点」的 IANA 偏移（不访问网络）。

为什么需要单独一个脚本：
  `check-manifest.py` 只校验 ±HHMM 的格式与范围，`verify-tags.py` 又拿 manifest 当事实源——
  两者都无法发现「manifest 和提交对象一起写错」的情况。这里用 Python 的 zoneinfo（IANA 时区库）
  独立算出该日当地 0 点的偏移，再与 manifest 对照。

约定：
  * 1970-01-01 及以后的日期必须与 IANA 偏移一致（含当日夏令时）。
  * 1970 年之前的提交统一存为 unix 0，时区不参与对象时间戳；默认跳过，
    用 --all 可一并检查（会报出 hk 1917 年按伦敦时间记为 +0000 的口径差异）。

用法：python3 tools/verify-tz.py [--all] [区域...]
"""
import datetime
import pathlib
import sys
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

REGIONS = {
    'cn': 'Asia/Shanghai',
    'hk': 'Asia/Hong_Kong',
    'tw': 'Asia/Taipei',
    'mo': 'Asia/Macau',
    'jp': 'Asia/Tokyo',
    'kr': 'Asia/Seoul',
    'kp': 'Asia/Pyongyang',
    'vn': 'Asia/Ho_Chi_Minh',
}
ROOT = pathlib.Path(__file__).resolve().parent.parent
CUTOFF = datetime.date(1970, 1, 1)


def main(argv):
    check_all = '--all' in argv
    args = [a for a in argv if not a.startswith('-')]
    regions = args or list(REGIONS)
    bad = skipped = total = 0

    for region in regions:
        if region not in REGIONS:
            print("   !! 未知区域：%s" % region)
            bad += 1
            continue
        manifest = ROOT / region / 'texts' / 'manifest.tsv'
        if not manifest.is_file():
            print("   !! 缺少清单：%s" % manifest)
            bad += 1
            continue
        zone = REGIONS[region]
        try:
            tz = ZoneInfo(zone)
        except ZoneInfoNotFoundError:
            print("   !! 系统缺少 IANA 时区数据：%s" % zone)
            return 1

        for n, line in enumerate(manifest.read_text(encoding='utf-8').split('\n'), 1):
            if not line or line.startswith('#'):
                continue
            f = line.split('\t')
            if len(f) != 7:
                continue
            date_s, tz_s = f[3], f[4]
            try:
                d = datetime.date.fromisoformat(date_s)
            except ValueError:
                print("   !! %s:%d 日期非法：%s" % (manifest, n, date_s))
                bad += 1
                continue
            if d < CUTOFF and not check_all:
                skipped += 1
                continue
            total += 1
            actual = datetime.datetime.combine(d, datetime.time.min, tzinfo=tz).strftime('%z')
            if actual != tz_s:
                print("   !! %s:%d %s 声明 %s，但 %s 当地 0 点为 %s"
                      % (manifest, n, date_s, tz_s, zone, actual))
                bad += 1

    print("  时区校验：%d 行；1970 前跳过 %d 行；%d 处不一致"
          % (total, skipped, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
