-- Testimonials: a short quote (+ optional rating) any user can leave once.
-- One row per user (unique user_hash); maintainer approves before it can show
-- on the public website. `id` keeps the user_hash out of API URLs.

create table if not exists testimonial (
  id text primary key,
  user_hash text not null unique references user_identity(user_hash) on delete cascade,
  body text not null check (length(body) between 10 and 500),
  rating integer check (rating is null or (rating between 1 and 5)),
  status text not null default 'pending'
    check (status in ('pending','approved','hidden')),
  is_featured integer not null default 0
    check (is_featured in (0, 1)),
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now'))
);

create index if not exists testimonial_public_idx
  on testimonial(status, is_featured desc, updated_at desc);
