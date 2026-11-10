// node n8n/build_fin_tracker.mjs [dump|create|update <id>]
// «[Fin] Трекер»: вся логіка в Supabase (supabase/001_fin_tracker.sql). Тут лише транспорт:
//   Telegram → insert у fin_inbox → тригер повертає reaction/reply → ставимо реакцію / шлемо текст.
//   Розклад: нд 19:00 звірка (weekly), 27-го 10:00 план (plan), 1-го 09:00 підсумок + запит залишку (month).
// Env n8n: FIN_TG_TOKEN — токен бота (лише для setMessageReaction, бо Telegram-вузол реакцій не вміє).
// Env білда (необов'язково): FIN_SB_CRED_ID, FIN_TG_CRED_ID, N8N_API_URL, N8N_API_KEY.
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const CFG = {
  supabase: { id: process.env.FIN_SB_CRED_ID || 'SET_ME', name: 'Fin Supabase' },
  telegram: { id: process.env.FIN_TG_CRED_ID || 'SET_ME', name: 'Fin Tracker Bot' },
}
let x = 0
const node = (name, type, typeVersion, parameters, extra = {}) => {
  const { y = 0, ...rest } = extra
  return { id: name.toLowerCase().replace(/[^a-z0-9]+/g, '-'), name, type, typeVersion, position: [(x += 220), y], parameters, ...rest }
}
const tg = { credentials: { telegramApi: CFG.telegram } }
const ifTrue = (id, left) => ({
  conditions: {
    options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 }, combinator: 'and',
    conditions: [{ id, leftValue: left, rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }],
  },
  options: {},
})

const prepare = `// лише текстові повідомлення; все інше (стікери, фото) ігноруємо
const m = $json.message || $json.channel_post;
if (!m || typeof m.text !== 'string') return [];
return [{ json: { kind: 'msg', chat_id: m.chat.id, message_id: m.message_id, reply_to: m.reply_to_message ? m.reply_to_message.message_id : null, text: m.text } }];`

const kind = `const kind = $('Schedule - Weekly Sun 19:00').isExecuted ? 'weekly'
  : $('Schedule - Plan 27th 10:00').isExecuted ? 'plan' : 'month';
return [{ json: { kind } }];`

const nodes = [
  node('Telegram Trigger', 'n8n-nodes-base.telegramTrigger', 1.1, { updates: ['message'], additionalFields: {} },
    { ...tg, webhookId: 'fin-tracker-tg-trigger' }),
  node('Code - Prepare Message', 'n8n-nodes-base.code', 2, { jsCode: prepare }),
  node('Schedule - Weekly Sun 19:00', 'n8n-nodes-base.scheduleTrigger', 1.2, { rule: { interval: [{ field: 'cronExpression', expression: '0 19 * * 0' }] } }, { y: 220 }),
  node('Schedule - Plan 27th 10:00', 'n8n-nodes-base.scheduleTrigger', 1.2, { rule: { interval: [{ field: 'cronExpression', expression: '0 10 27 * *' }] } }, { y: 380 }),
  node('Schedule - Month 1st 09:00', 'n8n-nodes-base.scheduleTrigger', 1.2, { rule: { interval: [{ field: 'cronExpression', expression: '0 9 1 * *' }] } }, { y: 540 }),
  node('Code - Schedule Kind', 'n8n-nodes-base.code', 2, { jsCode: kind }, { y: 380 }),
  // INSERT у fin_inbox: BEFORE INSERT тригер усе рахує і повертає reaction / reply / chat_id
  node('Supabase - Inbox', 'n8n-nodes-base.supabase', 1, { operation: 'create', tableId: 'fin_inbox', dataToSend: 'autoMapInputData' },
    { credentials: { supabaseApi: CFG.supabase } }),
  node('IF - Reaction?', 'n8n-nodes-base.if', 2.2, ifTrue('r', '={{ !!$json.reaction }}'), { y: -120 }),
  node('HTTP - Set Reaction', 'n8n-nodes-base.httpRequest', 4.2, {
    method: 'POST',
    url: '=https://api.telegram.org/bot{{ $env.FIN_TG_TOKEN }}/setMessageReaction',
    sendBody: true, specifyBody: 'json',
    jsonBody: '={{ JSON.stringify({ chat_id: $json.chat_id, message_id: $json.message_id, reaction: [{ type: "emoji", emoji: $json.reaction }] }) }}',
    options: {},
  }, { onError: 'continueRegularOutput', y: -120 }),
  node('IF - Reply?', 'n8n-nodes-base.if', 2.2, ifTrue('t', '={{ !!$json.reply }}'), { y: 120 }),
  node('Telegram - Send Reply', 'n8n-nodes-base.telegram', 1.2, {
    chatId: '={{ $json.chat_id }}',
    text: "={{ $json.reply.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') }}",
    additionalFields: { appendAttribution: false, parse_mode: 'HTML' },
  }, { ...tg, onError: 'continueRegularOutput', y: 120 }),
]

const to = (...ns) => ({ main: [ns.map(n => ({ node: n, type: 'main', index: 0 }))] })
const connections = {
  'Telegram Trigger': to('Code - Prepare Message'),
  'Code - Prepare Message': to('Supabase - Inbox'),
  'Schedule - Weekly Sun 19:00': to('Code - Schedule Kind'),
  'Schedule - Plan 27th 10:00': to('Code - Schedule Kind'),
  'Schedule - Month 1st 09:00': to('Code - Schedule Kind'),
  'Code - Schedule Kind': to('Supabase - Inbox'),
  'Supabase - Inbox': to('IF - Reaction?', 'IF - Reply?'),
  'IF - Reaction?': to('HTTP - Set Reaction'),
  'IF - Reply?': to('Telegram - Send Reply'),
}
const wf = { name: '[Fin] Трекер', nodes, connections, settings: { executionOrder: 'v1', timezone: 'Europe/Kyiv' } }
writeFileSync(join(here, 'fin_tracker.json'), JSON.stringify(wf, null, 2))

const mode = process.argv[2] || 'dump'
if (mode === 'dump') {
  console.log('dumped', nodes.length, 'nodes → n8n/fin_tracker.json')
} else {
  const base = String(process.env.N8N_API_URL || '').replace(/\/$/, '')
  if (!base || !process.env.N8N_API_KEY) throw new Error('потрібні N8N_API_URL і N8N_API_KEY')
  const api = base.endsWith('/api/v1') ? base : base + '/api/v1'
  const url = mode === 'update' ? `${api}/workflows/${process.argv[3]}` : `${api}/workflows`
  const r = await fetch(url, {
    method: mode === 'update' ? 'PUT' : 'POST',
    headers: { 'X-N8N-API-KEY': process.env.N8N_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(wf),
  })
  const t = await r.text()
  let j = null
  try { j = JSON.parse(t) } catch {}
  console.log(r.status, j ? `${j.id} ${j.name} active=${j.active}` : t.slice(0, 500))
}
