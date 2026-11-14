// Статистика TriniVoice на сервере: sudo trinivoice-stats [--all]
import fs from 'node:fs';
import { Stats } from './stats.js';

const file = process.argv[2] ?? '/var/lib/trinivoice/stats.json';
const showAll = process.argv.includes('--all');
try {
  fs.accessSync(file, fs.constants.R_OK);
} catch (e) {
  // папка данных закрыта (700): без sudo файл даже не виден — это EACCES, а не «нет файла»
  console.log(e.code === 'ENOENT'
    ? `Статистики пока нет (${file}): ещё никто не подключался`
    : 'Нет доступа к статистике: запустите через sudo — sudo trinivoice-stats');
  process.exit(1);
}
const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
const stats = new Stats({ file });
stats.online = raw.online ?? 0;
const fmt = (ms) => new Date(ms).toLocaleString('ru-RU', { timeZone: process.env.TZ || 'Europe/Moscow' });

console.log('TriniVoice — статистика');
console.log('=======================');
for (const line of stats.summaryLines()) console.log(line);
console.log(`(онлайн — на момент сохранения ${raw.savedAt ? fmt(Date.parse(raw.savedAt)) : '?'}, сохраняется раз в минуту)`);
console.log('');
const players = [...stats.players.values()].sort((a, b) => b.last - a.last);
const list = showAll ? players : players.slice(0, 50);
console.log(`${'Ник'.padEnd(26)}${'Версия'.padEnd(9)}${'Последний раз'.padEnd(22)}Впервые`);
for (const p of list) console.log(`${p.nick.padEnd(26)}${String(p.version || '?').padEnd(9)}${fmt(p.last).padEnd(22)}${fmt(p.first)}`);
if (!showAll && players.length > list.length) console.log(`… и ещё ${players.length - list.length}. Все: sudo trinivoice-stats --all`);
