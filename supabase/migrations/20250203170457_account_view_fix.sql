create or replace view public.account as
select
  a.account_id,
  a.created_via,
  a.username,
  a.created_at,
  a.account_display_name,
  a.num_tweets,
  a.num_following,
  a.num_followers,
  a.num_likes
from
  all_account a
  join archive_upload au on a.account_id = au.account_id
  and au.id = (
    (
      select
        max(archive_upload.id) as max
      from
        archive_upload
      where
        archive_upload.account_id = a.account_id
        AND
        archive_upload.upload_phase = 'completed'
    )
  );