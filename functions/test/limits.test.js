// Проверка лимитера и очереди на подставном Firestore.
// Отдельно ловим undefined в значениях — настоящий Firestore на них падает.
const admin = require('firebase-admin');

const store = new Map();
const clone = (o) => JSON.parse(JSON.stringify(o, (k, v) => (v === undefined ? '__UNDEF__' : v)));

function hasUndefined(obj) {
  const s = JSON.stringify(obj, (k, v) => (v === undefined ? '__UNDEF__' : v));
  return s.includes('__UNDEF__');
}

function docRef(path) {
  return {
    id: path.split('/').pop(),
    path,
    get: async () => ({ exists: store.has(path), id: path.split('/').pop(), data: () => store.get(path) }),
    set: async (data, opts) => {
      if (hasUndefined(data)) throw new Error(`undefined в значениях: ${path}`);
      const prev = opts && opts.merge ? store.get(path) || {} : {};
      store.set(path, { ...prev, ...data });
    },
    update: async (data) => {
      if (hasUndefined(data)) throw new Error(`undefined в значениях: ${path}`);
      store.set(path, { ...(store.get(path) || {}), ...data });
    },
  };
}

const fakeDb = {
  doc: (p) => docRef(p),
  collection: (c) => ({
    doc: (id) => docRef(`${c}/${id}`),
    where: () => ({
      count: () => ({ get: async () => ({ data: () => ({ count: 0 }) }) }),
    }),
  }),
  runTransaction: async (fn) =>
    fn({
      get: (ref) => ref.get(),
      set: (ref, data, opts) => ref.set(data, opts),
    }),
};

const realFirestore = admin.firestore;
const patched = () => fakeDb;
Object.assign(patched, realFirestore); // FieldValue / Timestamp остаются настоящими
// firestore на namespace объявлен геттером — простое присваивание не срабатывает.
Object.defineProperty(admin, 'firestore', { value: patched, configurable: true, writable: true });

const { limits, reserveSlot, gateSend, enqueue } = require('../lib/limits.js');

let fail = 0;
const ok = (name, cond) => {
  console.log((cond ? 'OK   ' : 'FAIL ') + name);
  if (!cond) fail++;
};

(async () => {
  // 1. Значения по умолчанию (config/risk пустой)
  const def = await limits();
  ok('по умолчанию 120 в час / 900 в сутки', def.hourLimit === 120 && def.dayLimit === 900 && def.enabled === true);

  // 2. Лимит в час: ставим 2 и пробуем отправить трижды
  store.set('config/risk', { hourLimit: 10, dayLimit: 100 });
  await new Promise((r) => setTimeout(r, 1)); // сбросить кэш нельзя — читаем заново ниже
  // кэш настроек живёт минуту, поэтому дергаем внутренний путь через reserveSlot после сброса модуля
  delete require.cache[require.resolve('../lib/limits.js')];
  const L2 = require('../lib/limits.js');

  let last;
  for (let i = 0; i < 10; i++) last = await L2.reserveSlot();
  const over = await L2.reserveSlot();
  ok('десять отправок в час прошли', last.allow && last.hour === 10);
  ok('одиннадцатая упёрлась в часовой лимит', !over.allow && over.reason === 'hour');

  // 3. Суточный лимит
  store.delete('riskState/_channel');
  store.set('config/risk', { hourLimit: 1000, dayLimit: 50 });
  delete require.cache[require.resolve('../lib/limits.js')];
  const L3 = require('../lib/limits.js');
  for (let i = 0; i < 50; i++) await L3.reserveSlot();
  const d = await L3.reserveSlot();
  ok('суточный лимит срабатывает', !d.allow && d.reason === 'day');

  // 4. «Один текст многим» уходит в очередь
  store.delete('riskState/_channel');
  store.delete('riskState/u1');
  store.set('config/risk', { hourLimit: 500, dayLimit: 5000 });
  delete require.cache[require.resolve('../lib/limits.js')];
  const L4 = require('../lib/limits.js');
  const text = 'Здравствуйте! Ждём вас завтра в клинике DR.TOITAYEV по адресу Сатпаева 30';
  const gates = [];
  for (let i = 1; i <= 6; i++) {
    gates.push(await L4.gateSend({ authorId: 'u1', chatId: '7770000000' + i, text }));
  }
  ok('первые 4 адресата уходят сразу', gates.slice(0, 4).every((g) => g.send));
  ok('с 5-го — очередь по правилу mass', gates[4].send === false && gates[4].reason === 'mass');

  // 5. Живая переписка (разные тексты) очередью не тормозится
  store.delete('riskState/u2');
  const live = [];
  for (let i = 1; i <= 8; i++) {
    live.push(await L4.gateSend({ authorId: 'u2', chatId: '7771111111' + i, text: 'Да, конечно' }));
  }
  ok('короткие ответы («Да, конечно») рассылкой не считаются', live.every((g) => g.send));

  // 5б. Длинный шаблон многим — это рассылка, придерживаем
  store.delete('riskState/u3');
  const tpl = [];
  for (let i = 1; i <= 6; i++) {
    tpl.push(await L4.gateSend({ authorId: 'u3', chatId: '7772222222' + i, text: 'Здравствуйте! Напоминаем о приёме завтра в клинике DR.TOITAYEV' }));
  }
  ok('длинный шаблон с 5-го уходит в очередь', tpl[4].send === false && tpl[4].reason === 'mass');

  // 6. Постановка в очередь: без undefined и с нужными полями
  await L4.enqueue({
    kind: 'text',
    chatId: '77471234567',
    text: 'Текст в очередь',
    authorId: 'u1',
    crmMessageId: 'cm1',
    reason: 'mass',
    // name / refMessageId / replyToText специально не переданы (были undefined)
  });
  const outbox = store.get('outbox/cm1');
  const msg = store.get('messages/cm1');
  const conv = store.get('conversations/77471234567');
  ok('outbox создан со статусом pending', outbox && outbox.status === 'pending' && outbox.attempts === 0);
  ok('в outbox нет undefined-полей', outbox && !hasUndefined(clone(outbox)));
  ok('сообщение видно в чате как queued', msg && msg.status === 'queued' && msg.queued === true);
  ok('в списке чатов обновился превью', conv && conv.lastMessagePreview === 'Текст в очередь');

  // 7. Медиа в очередь (правило mass не применяется)
  const g = await L4.gateSend({ authorId: 'u1', chatId: '77471234567', text: '[image]', skipMass: true });
  ok('медиа не попадает под mass', g.send === true);

  console.log(fail === 0 ? '\nВСЕ ПРОВЕРКИ ПРОШЛИ' : `\nПРОВАЛЕНО: ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error('ОШИБКА:', e);
  process.exit(1);
});
