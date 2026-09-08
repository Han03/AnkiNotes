#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将旧的 .metadata/quiz_questions.json 中的题目按笔记拆分到 Questions/ 目录下。

使用方法：
    python migrate_quiz_to_questions.py [AnkiNotes根目录]

如果不指定目录，默认使用当前目录下的 AnkiNotes 或 C:\\Data\\AnkiNotes。

数据结构：
- 输入：.metadata/quiz_questions.json  (所有题目的数组)
- 输入：.metadata/notes_index.json      (笔记索引，包含 id, title, folderId)
- 输入：.metadata/folders.json          (文件夹索引，包含 id, name, parentId)
- 输出：Questions/[文件夹路径]/[笔记标题].json  (每个笔记的题目数组)
"""

import json
import os
import re
import sys
from pathlib import Path


def sanitize_filename(name: str) -> str:
    """清理文件名，去除非法字符"""
    # 替换 Windows 非法字符
    name = re.sub(r'[<>:"/\\|?*]', '_', name)
    # 去除首尾空格和点
    name = name.strip().strip('.')
    # 限制长度
    if len(name) > 200:
        name = name[:200]
    return name if name else 'untitled'


def build_folder_path(folder_id: str, folders: dict) -> list:
    """根据文件夹 ID 递归构建路径（从根到当前）"""
    path = []
    current_id = folder_id
    visited = set()  # 防止循环引用
    
    while current_id and current_id not in visited:
        visited.add(current_id)
        folder = folders.get(current_id)
        if not folder:
            break
        path.append(folder.get('name', 'unknown'))
        current_id = folder.get('parentId')
    
    # 反转，从根到当前
    path.reverse()
    return path


def load_json(filepath: Path, default):
    """加载 JSON 文件，失败返回默认值"""
    if not filepath.exists():
        print(f"⚠️  文件不存在: {filepath}")
        return default
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        print(f"⚠️  读取失败 {filepath}: {e}")
        return default


def main():
    # 确定 AnkiNotes 根目录
    if len(sys.argv) > 1:
        root_dir = Path(sys.argv[1])
    else:
        # 尝试常见路径
        candidates = [
            Path.cwd() / 'AnkiNotes',
            Path('C:/Data/AnkiNotes'),
            Path('/mnt/c/Data/AnkiNotes'),
        ]
        root_dir = None
        for candidate in candidates:
            if candidate.exists():
                root_dir = candidate
                break
        if root_dir is None:
            print("❌ 未找到 AnkiNotes 目录，请指定路径：")
            print("   python migrate_quiz_to_questions.py C:\\Data\\AnkiNotes")
            sys.exit(1)
    
    print(f"📂 根目录: {root_dir}")
    
    # 检查必要文件
    metadata_dir = root_dir / '.metadata'
    quiz_file = metadata_dir / 'quiz_questions.json'
    notes_file = metadata_dir / 'notes_index.json'
    folders_file = metadata_dir / 'folders.json'
    
    if not quiz_file.exists():
        print(f"❌ 未找到 quiz_questions.json: {quiz_file}")
        sys.exit(1)
    
    # 加载数据
    print("\n📖 加载数据...")
    questions = load_json(quiz_file, [])
    notes_list = load_json(notes_file, [])
    folders_list = load_json(folders_file, [])
    
    print(f"   题目数量: {len(questions)}")
    print(f"   笔记数量: {len(notes_list)}")
    print(f"   文件夹数量: {len(folders_list)}")
    
    if not questions:
        print("⚠️  quiz_questions.json 为空，无需迁移")
        return
    
    # 构建索引
    notes_by_id = {}
    for note in notes_list:
        note_id = note.get('id')
        if note_id:
            notes_by_id[note_id] = note
    
    folders_by_id = {}
    for folder in folders_list:
        folder_id = folder.get('id')
        if folder_id:
            folders_by_id[folder_id] = folder
    
    # 按 noteId 分组题目
    print("\n🔄 按笔记分组题目...")
    questions_by_note = {}
    orphan_questions = []  # 找不到对应笔记的题目
    
    for q in questions:
        note_id = q.get('noteId')
        if note_id and note_id in notes_by_id:
            if note_id not in questions_by_note:
                questions_by_note[note_id] = []
            questions_by_note[note_id].append(q)
        else:
            orphan_questions.append(q)
    
    print(f"   有对应笔记的题目: {sum(len(v) for v in questions_by_note.values())}")
    print(f"   孤儿题目（无对应笔记）: {len(orphan_questions)}")
    
    # 创建 Questions 目录
    questions_dir = root_dir / 'Questions'
    questions_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n📁 输出目录: {questions_dir}")
    
    # 按笔记保存题目
    print("\n💾 保存题目文件...")
    success_count = 0
    failed_count = 0
    
    for note_id, note_questions in questions_by_note.items():
        note = notes_by_id[note_id]
        title = note.get('title', 'untitled')
        folder_id = note.get('folderId')
        
        # 计算文件夹路径
        folder_path = []
        if folder_id:
            folder_path = build_folder_path(folder_id, folders_by_id)
        
        # 创建目录
        target_dir = questions_dir
        for folder_name in folder_path:
            safe_name = sanitize_filename(folder_name)
            target_dir = target_dir / safe_name
        target_dir.mkdir(parents=True, exist_ok=True)
        
        # 保存文件
        safe_title = sanitize_filename(title)
        target_file = target_dir / f"{safe_title}.json"
        
        try:
            with open(target_file, 'w', encoding='utf-8') as f:
                json.dump(note_questions, f, ensure_ascii=False, indent=2)
            success_count += 1
            path_str = '/'.join(folder_path + [f"{safe_title}.json"])
            print(f"   ✅ {path_str} ({len(note_questions)} 题)")
        except Exception as e:
            failed_count += 1
            print(f"   ❌ {title}: {e}")
    
    # 处理孤儿题目
    if orphan_questions:
        orphan_dir = questions_dir / '_orphan'
        orphan_dir.mkdir(parents=True, exist_ok=True)
        orphan_file = orphan_dir / 'orphan_questions.json'
        try:
            with open(orphan_file, 'w', encoding='utf-8') as f:
                json.dump(orphan_questions, f, ensure_ascii=False, indent=2)
            print(f"\n⚠️  孤儿题目已保存到: {orphan_file} ({len(orphan_questions)} 题)")
        except Exception as e:
            print(f"\n❌ 保存孤儿题目失败: {e}")
    
    # 统计
    print("\n" + "=" * 50)
    print("📊 迁移完成统计:")
    print(f"   成功: {success_count} 个笔记文件")
    print(f"   失败: {failed_count} 个")
    print(f"   总题目: {len(questions)}")
    print(f"   有对应笔记: {sum(len(v) for v in questions_by_note.values())}")
    print(f"   孤儿题目: {len(orphan_questions)}")
    print("=" * 50)
    
    # 备份旧文件
    backup_file = quiz_file.with_suffix('.json.bak')
    try:
        quiz_file.rename(backup_file)
        print(f"\n💾 旧文件已备份为: {backup_file}")
        print("   确认迁移无误后可删除此备份文件")
    except Exception as e:
        print(f"\n⚠️  备份旧文件失败: {e}")
        print("   请手动删除或备份 quiz_questions.json")


if __name__ == '__main__':
    main()
