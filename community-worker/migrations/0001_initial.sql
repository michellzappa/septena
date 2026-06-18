-- Septena community backend foundation.
-- D1 / SQLite dialect. All writes are mediated by the Worker.

create table if not exists user_identity (
  user_hash text primary key,
  created_at text not null default (datetime('now')),
  last_seen_at text not null default (datetime('now')),
  role text not null default 'user'
    check (role in ('user','maintainer','moderator')),
  is_banned integer not null default 0
    check (is_banned in (0, 1))
);

create table if not exists user_profile (
  user_hash text primary key references user_identity(user_hash) on delete cascade,
  username text unique,
  display_name text,
  avatar_key text,
  bio text,
  is_public integer not null default 0
    check (is_public in (0, 1)),
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now')),
  check (username is null or (length(username) between 3 and 24)),
  check (display_name is null or length(display_name) <= 80),
  check (bio is null or length(bio) <= 280)
);

create table if not exists support_ticket (
  id text primary key,
  user_hash text not null references user_identity(user_hash),
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now')),
  last_message_at text not null default (datetime('now')),
  status text not null default 'open'
    check (status in ('open','waiting_on_user','waiting_on_maintainer','closed')),
  category text not null
    check (category in ('bug','account','data','idea','other')),
  subject text not null check (length(subject) between 3 and 140),
  app_version text,
  build text,
  platform text,
  os_version text,
  device_model text,
  app_locale text
);

create index if not exists support_ticket_user_idx
  on support_ticket(user_hash, last_message_at desc);

create table if not exists support_message (
  id text primary key,
  ticket_id text not null references support_ticket(id) on delete cascade,
  author_hash text not null references user_identity(user_hash),
  author_role text not null
    check (author_role in ('user','maintainer','moderator')),
  body text not null check (length(body) between 1 and 4000),
  is_internal integer not null default 0
    check (is_internal in (0, 1)),
  created_at text not null default (datetime('now'))
);

create index if not exists support_message_ticket_idx
  on support_message(ticket_id, created_at asc);

create table if not exists support_attachment (
  id text primary key,
  ticket_id text not null references support_ticket(id) on delete cascade,
  message_id text references support_message(id) on delete cascade,
  object_key text not null,
  mime_type text not null,
  byte_size integer not null check (byte_size > 0),
  created_at text not null default (datetime('now'))
);

create table if not exists feature_request (
  id text primary key,
  author_hash text not null references user_identity(user_hash),
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now')),
  title text not null check (length(title) between 3 and 120),
  detail text check (detail is null or length(detail) <= 4000),
  status text not null default 'pending'
    check (status in ('pending','approved','planned','in_progress','shipped','rejected','merged')),
  maintainer_note text check (maintainer_note is null or length(maintainer_note) <= 2000),
  merged_into text references feature_request(id),
  is_locked integer not null default 0
    check (is_locked in (0, 1))
);

create index if not exists feature_request_status_idx
  on feature_request(status, created_at desc);

create table if not exists feature_vote (
  request_id text not null references feature_request(id) on delete cascade,
  user_hash text not null references user_identity(user_hash),
  created_at text not null default (datetime('now')),
  primary key (request_id, user_hash)
);

create table if not exists feature_comment (
  id text primary key,
  request_id text not null references feature_request(id) on delete cascade,
  author_hash text not null references user_identity(user_hash),
  author_role text not null
    check (author_role in ('user','maintainer','moderator')),
  parent_id text references feature_comment(id),
  body text not null check (length(body) between 1 and 2000),
  created_at text not null default (datetime('now')),
  updated_at text,
  status text not null default 'visible'
    check (status in ('visible','hidden','deleted')),
  is_pinned integer not null default 0
    check (is_pinned in (0, 1))
);

create index if not exists feature_comment_request_idx
  on feature_comment(request_id, created_at asc);

create table if not exists moderation_report (
  id text primary key,
  reporter_hash text not null references user_identity(user_hash),
  target_type text not null check (target_type in ('feature','comment','profile')),
  target_id text not null,
  reason text not null check (length(reason) between 3 and 500),
  created_at text not null default (datetime('now')),
  status text not null default 'open'
    check (status in ('open','reviewed','dismissed','actioned'))
);

create table if not exists admin_audit_log (
  id text primary key,
  actor_hash text not null references user_identity(user_hash),
  action text not null,
  target_type text not null,
  target_id text not null,
  detail text,
  created_at text not null default (datetime('now'))
);
