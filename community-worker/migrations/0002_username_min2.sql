-- Allow 2-character usernames (e.g. "mz"). SQLite can't ALTER a CHECK
-- constraint in place, so rebuild user_profile with the relaxed bound and
-- copy the existing rows across. Everything else is identical to 0001.

pragma foreign_keys = off;

create table user_profile_new (
  user_hash text primary key references user_identity(user_hash) on delete cascade,
  username text unique,
  display_name text,
  avatar_key text,
  bio text,
  is_public integer not null default 0
    check (is_public in (0, 1)),
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now')),
  check (username is null or (length(username) between 2 and 24)),
  check (display_name is null or length(display_name) <= 80),
  check (bio is null or length(bio) <= 280)
);

insert into user_profile_new
  (user_hash, username, display_name, avatar_key, bio, is_public, created_at, updated_at)
select
  user_hash, username, display_name, avatar_key, bio, is_public, created_at, updated_at
from user_profile;

drop table user_profile;
alter table user_profile_new rename to user_profile;

pragma foreign_keys = on;
