#!/usr/bin/env python3
"""检测 CI（Xcode 26）会报错、但本机工具链放行的初始化写法：

    非可选存储属性（无 `?` / `!` / 默认值），在 super.init(...) 之后才赋值。

本机 Swift 6.1.2 / 6.4.2 接受该写法，CI 的 Xcode 26 报
"property 'self.x' not initialized at super.init call"，typecheck 查不出来。
用法: tools/lint-stored-props.py <file.swift> [...]
"""
import re
import sys

# 成员级属性声明（无默认值、无计算属性体）
PROP_RE = re.compile(
    r'^\s*(?:(?:private|fileprivate|internal|public|open)\s+)?'
    r'(let|var)\s+(\w+)\s*:\s*([^={\n]+?)\s*$'
)
TYPE_DECL_RE = re.compile(
    r'^\s*(?:@\w+\s+)*(?:(?:final|public|open|internal|private|fileprivate)\s+)*'
    r'(?:class|struct|enum)\s+(\w+)'
)
INIT_RE = re.compile(
    r'^\s*(?:@\w+\s+)*(?:(?:public|open|internal|private|fileprivate|convenience|required)\s+)*'
    r'init\s*[?!]?\s*\('
)
SUPER_INIT_RE = re.compile(r'\bsuper\.init\s*\(')


def indent_of(line):
    return len(line) - len(line.lstrip())


def member_spans(lines, start, end):
    """在类块内，返回顶层成员（缩进 = 第一个成员缩进）的 [(decl_line, body_start, body_end)]。"""
    members = []
    i = start + 1
    base = None
    while i < end:
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        ind = indent_of(line)
        if base is None:
            base = ind
        if ind != base:
            i += 1
            continue
        # 该行是成员起点，找它的结束（花括号平衡）
        depth = line.count('{') - line.count('}')
        j = i
        if depth > 0:
            j = i + 1
            while j < end and depth > 0:
                depth += lines[j].count('{') - lines[j].count('}')
                j += 1
            j -= 1
        members.append((i, i, j))
        i = j + 1
    return members


def check(path):
    lines = open(path, encoding='utf-8').read().splitlines()
    problems = []
    n = len(lines)
    depth = 0
    for i, line in enumerate(lines):
        if TYPE_DECL_RE.match(line) and depth == 0:
            # 类块范围
            d = 0
            end = i
            for j in range(i, n):
                d += lines[j].count('{') - lines[j].count('}')
                if d == 0 and '{' in ''.join(lines[i:j + 1]):
                    end = j
                    break
            # 收集本类非可选、无默认值的存储属性
            props = {}
            for (decl, _, _) in member_spans(lines, i, end):
                m = PROP_RE.match(lines[decl])
                if not m:
                    continue
                kind, name, typ = m.group(1), m.group(2), m.group(3).strip()
                if typ.endswith('?') or typ.endswith('!'):
                    continue
                if '{' in typ:
                    continue
                props[name] = decl
            if props:
                # 逐个 init 检查：super.init 之后是否还给这些属性赋值
                for (decl, body_start, body_end) in member_spans(lines, i, end):
                    if not INIT_RE.match(lines[decl]):
                        continue
                    sup = next(
                        (k for k in range(body_start, body_end + 1) if SUPER_INIT_RE.search(lines[k])),
                        None,
                    )
                    if sup is None:
                        continue
                    for name, prop_line in props.items():
                        for k in range(sup + 1, body_end + 1):
                            if re.match(rf'^\s*(?:self\.)?{re.escape(name)}\s*=(?!=)', lines[k]):
                                problems.append(
                                    f'{path}:{k + 1}: 属性「{name}」（第 {prop_line + 1} 行声明）'
                                    f'在 super.init 之后才赋值，Xcode 26 会报错：'
                                    f'给它加默认值、改成可选（? / !）或移到 super.init 之前'
                                )
                                break
        depth += line.count('{') - line.count('}')
    return problems


def main():
    problems = []
    for path in sys.argv[1:]:
        problems += check(path)
    for p in problems:
        print(p)
    if problems:
        print('STORED-PROP LINT FAILED')
        sys.exit(1)
    print('STORED-PROP LINT OK')


if __name__ == '__main__':
    main()
