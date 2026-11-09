# Lead Engine: «Вакансії як сигнал»

## Ідея
Вакансія = компанія сама назвала біль, бюджет і терміновість. Не відгукуємось через сайт, а знаходимо власника і пропонуємо **«Міст → Помічник»** з готовим результатом.

## MVP (1 тиждень, 1 роль: SMM/контент-менеджер)
```
Cron 09:00 (n8n)
 → Парсинг Work.ua / robota.ua (ключі: SMM, контент-менеджер, таргетолог-SMM, копірайтер)
 → Фільтр: не кадрові агенції, не держсектор, малий бізнес
 → Supabase upsert (дедуп; first_seen, last_seen, repost_count, is_promoted)
 → Opendatabot API → директор (ПІБ), статус компанії
 → Пошук Instagram/сайту; дата останнього поста
 → Claude: score 1–10, причина, оффер (міст/дешевший найм/тестове), чернетка повідомлення, 3 пости в їхньому стилі
 → Апрув у Mini App (перевикористати travellab-approve): відправити / правка / скіп
 → Ручна відправка → статус у CRM
 → Follow-up нагадування на день 3 і 7
```

## Таблиці Supabase (чернетка)
- `vacancies`: source, url, company_name, title, salary, contact_name, phone, posted_at, first_seen, last_seen, repost_count, is_promoted, raw.
- `companies`: name, edrpou, director, size_hint, instagram, site, last_ig_post_at.
- `leads`: company_id, vacancy_id, score, reason, offer_type, draft_message, proof_assets, status (new/approved/sent/replied/call/won/lost), next_followup_at.

## Пріоритет ліда
🔥 перевиставлена / платно піднята + малий бізнес + директор = контакт у вакансії + живий Instagram.

## Ризики
- У Work.ua немає API, тому парсимо HTML (можливі блоки: проксі/Apify).
- Персональні дані: зберігаємо мінімум, тільки публічне.
- Відправка тільки вручну після апруву (захист від бану).

## Метрика успіху MVP
За 2 тижні: 50+ відправлених повідомлень → ≥5 відповідей → ≥1 дзвінок.
