#!/usr/bin/env python3
"""
Folo-Read 审核清单生成器
每次 folo 过滤后运行此脚本，生成标准化审核清单。
解决之前每次格式不一致的问题。
"""
import json, os, sys, time, html
from collections import OrderedDict

PIPELINE = os.path.expanduser('/app/projects/folo/docs/Folo-Read/unread-articles/pipeline-state.json')
FEED_MAP = '/tmp/feed_map.json'
CUTOFF = '/tmp/analyze_cutoff'
OUTPUT = '/tmp/folo_review.txt'

def load_pipeline():
    with open(PIPELINE) as f:
        return json.load(f)

def load_feed_map():
    if not os.path.exists(FEED_MAP):
        return {}
    with open(FEED_MAP) as f:
        data = json.load(f)
    return data.get('entryFeedMap', {})

def find_new_ids(data):
    """Find entries downloaded after cutoff."""
    if not os.path.exists(CUTOFF):
        print("WARN: no cutoff file, showing all rejected", file=sys.stderr)
        return set(data.keys())

    cutoff = os.path.getmtime(CUTOFF)
    base = os.path.dirname(PIPELINE)
    new_dirs = set()

    for root, dirs, files in os.walk(base):
        for d in dirs:
            full = os.path.join(root, d)
            if os.path.exists(os.path.join(full, 'index.html')):
                if os.path.getmtime(full) > cutoff:
                    new_dirs.add(os.path.basename(full))

    new_ids = set()
    for dname in new_dirs:
        suffix = dname[-8:] if len(dname) >= 8 else dname
        for eid in data:
            if suffix in eid and data[eid].get('title') != '?':
                new_ids.add(eid)
    return new_ids

def bucket_reason(reason, category, subcat):
    """Classify reject reason into display bucket."""
    r = f"{reason} {category} {subcat}".lower()
    if '重复' in r or 'duplicate' in r:
        return '🔁 重复'
    if any(w in r for w in ['audio','tts','asr','speech','语音']):
        return '🔊 Audio/TTS'
    if any(w in r for w in ['具身','embodied','机器人','robot','humanoid','世界模型','world action']):
        return '🤖 具身智能/机器人'
    if any(w in r for w in ['vision','gui','图像','visual','image gen','gpt image']):
        return '🎨 Vision AI/GUI'
    if any(w in r for w in ['融资','商业','business','估值','收购','ipo','股价','cloud grew','资本支出']):
        return '💼 商业/融资'
    if any(w in r for w in ['推广','营销','promotion','marketing','产品发','product ann','产品宣',
                               '宣传文','产品公','合作推','product la','产品更','公告','功能升',
                               '功能发','功能宣','产品安','限免','促销','app store']):
        return '📢 产品推广/发布'
    if any(w in r for w in ['标题党','炒作','hype']):
        return '📰 标题党'
    if any(w in r for w in ['政治','politic','trump','social','社会新','个人','无技术','杂项',
                               '杂谈','日常','趣闻','教育','生活','非技术','non-tech','非AI',
                               'no technical','entertain','游戏','lacks tech','社交','哲学',
                               'personal','日常分','日常分','个人生','个人建','科普讲','励志',
                               'silicon valley','ron conway','科学成','quip','quip']):
        return '📭 非技术/杂项'
    return '❓ 其他'

BUCKET_ORDER = [
    '📭 非技术/杂项',
    '📢 产品推广/发布',
    '💼 商业/融资',
    '🎨 Vision AI/GUI',
    '🤖 具身智能/机器人',
    '🔊 Audio/TTS',
    '📰 标题党',
    '🔁 重复',
    '❓ 其他',
]

def clean_text(s):
    """Remove HTML entities and control characters."""
    if not s:
        return '?'
    s = html.unescape(s)
    s = s.replace('&#039;', "'").replace('&amp;', '&').replace('&quot;', '"')
    s = s.replace('&ensp;', ' ').replace('&emsp;', ' ')
    return s

def generate(data, feed_map, new_ids):
    rejected = [(eid, v) for eid, v in data.items()
                if v.get('should_reject') and eid in new_ids]

    # Sort into buckets
    buckets = OrderedDict()
    for bname in BUCKET_ORDER:
        buckets[bname] = []
    for eid, v in rejected:
        b = bucket_reason(v.get('reject_reason',''), v.get('category',''), v.get('subscription_category',''))
        if b not in buckets:
            buckets[b] = []
        buckets[b].append((eid, v))

    lines = []
    lines.append(f"# Folo 审核清单")
    lines.append(f"# 生成时间: {time.strftime('%Y-%m-%d %H:%M')}")
    lines.append(f"# 本轮被拒: {len(rejected)}篇\n")

    idx = 0
    for bname in BUCKET_ORDER:
        items = buckets.get(bname, [])
        if not items:
            continue
        lines.append("=" * 70)
        lines.append(f"【{bname}】（{len(items)}篇）")
        lines.append("=" * 70)

        # Sort items within bucket by title for deterministic output
        items.sort(key=lambda x: clean_text(x[1].get('title','')).lower())

        for eid, v in items:
            idx += 1
            feed_name = feed_map.get(eid, v.get('subscription_category', '?'))
            title = clean_text(v.get('title', '?'))
            reason = clean_text(v.get('reject_reason', '?'))
            summary = clean_text(v.get('summary', '?'))
            url = v.get('url', '?')
            lang = v.get('language', '?')
            subcat = v.get('subscription_category', '?')

            lines.append(f"\n**{idx}. {title[:150]}**")
            lines.append(f"来源: {feed_name} | {subcat} | {lang}")
            lines.append(f"拒绝理由: {reason}")
            lines.append(f"简介: {summary}")
            lines.append(f"URL: {url}")

    # Borderline cases
    lines.append(f"\n{'='*70}")
    lines.append("【边界案例·重点关注】")
    lines.append("=" * 70)

    borderline = identify_borderline(buckets, feed_map)
    if borderline:
        for note in borderline:
            lines.append(note)
    else:
        lines.append("本轮无争议边界案例。")

    lines.append(f"\n---")
    lines.append(f"总计 {idx} 篇被拒文章。请逐篇审核，回复编号即可（如「捞 4,11,25」）。")

    return '\n'.join(lines)

def identify_borderline(buckets, feed_map):
    """Identify articles that may warrant user rescue per AGENT.md rules."""
    notes = []
    all_items = []
    for bname in BUCKET_ORDER:
        for eid, v in buckets.get(bname, []):
            all_items.append((eid, v, bname))

    for eid, v, bucket in all_items:
        title = clean_text(v.get('title', ''))
        reason = clean_text(v.get('reject_reason', ''))
        subcat = v.get('subscription_category', '')
        feed = feed_map.get(eid, '')

        # AGENT.md rescue rules
        if 'Karpathy' in feed or 'karpathy' in title.lower():
            notes.append(f"⚠ #{get_idx(eid)} {title[:80]} — Karpathy 高优先级来源")
        elif 'Notion' in feed and ('Agent' in title or 'Data Scout' in title):
            notes.append(f"⚠ #{get_idx(eid)} {title[:80]} — Notion更新（AGENT.md规定全保留）")
        elif subcat == 'AutoSum' and ('prompting' in reason or 'experiment' in title.lower() or 'gambler' in title.lower()):
            notes.append(f"⚠ #{get_idx(eid)} {title[:80]} — AutoSum来源 + AI实验内容")
        elif 'Cursor' in title and 'SDK' in title:
            notes.append(f"⚠ #{get_idx(eid)} {title[:80]} — 编码Agent基础设施，有参考价值")
        elif 'GLM-5V' in title and subcat == 'PAPER':
            notes.append(f"⚠ #{get_idx(eid)} {title[:80]} — PAPER来源，Vision但有方法论")
        elif 'Granite Speech' in title and subcat == 'AutoSum':
            notes.append(f"⚠ #{get_idx(eid)} {title[:80]} — AutoSum来源，开源ASR模型发布")

    return notes if notes else None

def get_idx(target_eid):
    """Get the display index of an entry (assigned during generation)."""
    return '?'

def main():
    data = load_pipeline()
    feed_map = load_feed_map()
    new_ids = find_new_ids(data)

    output = generate(data, feed_map, new_ids)

    with open(OUTPUT, 'w') as f:
        f.write(output)

    # Also print to stdout so caller can see result
    print(output)

if __name__ == '__main__':
    main()
