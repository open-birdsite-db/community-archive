
DROP FUNCTION IF EXISTS tes_get_tweets_on_this_day(INTEGER, TEXT);
DROP FUNCTION IF EXISTS tes_get_tweet_counts_by_date(TEXT);
DROP FUNCTION IF EXISTS tes_get_moots(TEXT);
DROP FUNCTION IF EXISTS tes_get_followers(TEXT);
DROP FUNCTION IF EXISTS tes_get_followings(TEXT);
DROP FUNCTION IF EXISTS tes_search_liked_tweets CASCADE;
DROP FUNCTION IF EXISTS tes_search_tweets CASCADE;



-- Helper function to get current user's account_id
CREATE OR REPLACE FUNCTION tes.get_current_account_id()
RETURNS TEXT AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    SELECT a.account_id INTO v_account_id
    FROM auth.users u
    JOIN account a ON a.account_id = u.raw_user_meta_data->>'provider_id'
    WHERE u.id = auth.uid();
    
    RETURN v_account_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION tes.get_tweets_on_this_day(
    p_limit INTEGER DEFAULT NULL
)
RETURNS TABLE (
    tweet_id TEXT,
    account_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    full_text TEXT,
    retweet_count INTEGER,
    favorite_count INTEGER,
    reply_to_tweet_id TEXT,
    reply_to_user_id TEXT,
    reply_to_username TEXT,
    username TEXT,
    account_display_name TEXT,
    avatar_media_url TEXT
) AS $$
DECLARE
    current_month INTEGER;
    current_day INTEGER;
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    -- Get the current month and day
    SELECT EXTRACT(MONTH FROM CURRENT_DATE), EXTRACT(DAY FROM CURRENT_DATE)
    INTO current_month, current_day;

    RETURN QUERY
    SELECT 
        t.tweet_id, t.account_id, t.created_at, t.full_text, t.retweet_count,
        t.favorite_count, t.reply_to_tweet_id, t.reply_to_user_id, t.reply_to_username,
        a.username, a.account_display_name, p.avatar_media_url
    FROM 
        public.tweets t
        inner join account a on t.account_id = a.account_id
        inner join profile p on t.account_id = p.account_id
    WHERE 
        EXTRACT(MONTH FROM t.created_at AT TIME ZONE 'UTC') = current_month
        AND EXTRACT(DAY FROM t.created_at AT TIME ZONE 'UTC') = current_day
        AND EXTRACT(YEAR FROM t.created_at AT TIME ZONE 'UTC') < EXTRACT(YEAR FROM CURRENT_DATE)
        AND t.account_id = v_account_id
    ORDER BY 
        t.favorite_count DESC, t.retweet_count DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION tes.get_tweet_counts_by_date()
RETURNS TABLE (tweet_date DATE, tweet_count BIGINT) AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    RETURN QUERY
    SELECT 
        DATE(created_at) AS tweet_date,
        COUNT(*) AS tweet_count
    FROM 
        public.tweets
    WHERE 
        account_id = v_account_id
    GROUP BY 
        DATE(created_at)
    ORDER BY 
        tweet_date;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION tes.get_moots()
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    RETURN QUERY
    SELECT 
        f1.follower_account_id as account_id,
        mu.screen_name as username
    FROM public.followers f1
    INNER JOIN public.following f2 
        ON f1.account_id = f2.account_id 
        AND f1.follower_account_id = f2.following_account_id
    left join mentioned_users mu on mu.user_id = f1.follower_account_id
    where f1.account_id = v_account_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION tes.get_followers()
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    RETURN QUERY
    SELECT 
        f1.follower_account_id AS account_id,
        mu.screen_name AS username
    FROM public.followers f1
    LEFT JOIN mentioned_users mu ON mu.user_id = f1.follower_account_id
    WHERE f1.account_id = v_account_id and mu.screen_name is not null;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION tes.get_followings()
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    RETURN QUERY
    SELECT 
        f2.following_account_id AS account_id,
        mu.screen_name AS username
    FROM public.following f2
    LEFT JOIN mentioned_users mu ON mu.user_id = f2.following_account_id
    WHERE f2.account_id = v_account_id and mu.screen_name is not null;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION tes.search_liked_tweets(
  search_query TEXT,
  from_user TEXT DEFAULT NULL,
  to_user TEXT DEFAULT NULL,
  since_date DATE DEFAULT NULL,
  until_date DATE DEFAULT NULL,
  min_likes INTEGER DEFAULT 0,
  min_retweets INTEGER DEFAULT 0,
  max_likes INTEGER DEFAULT 100000000,
  max_retweets INTEGER DEFAULT 100000000,
  limit_ INTEGER DEFAULT 50
)
RETURNS TABLE (
  tweet_id TEXT,
  account_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE,
  full_text TEXT,
  retweet_count INTEGER,
  favorite_count INTEGER,
  reply_to_tweet_id TEXT,
  avatar_media_url TEXT,
  archive_upload_id BIGINT,
  username TEXT,
  account_display_name TEXT
) AS $$
DECLARE
  from_account_id TEXT;
  to_account_id TEXT;
  v_account_id TEXT;
BEGIN
  -- Get the current user's account_id
  v_account_id := tes.get_current_account_id();

  -- Get account_id for from_user
  IF from_user IS NOT NULL THEN
    SELECT a.account_id INTO from_account_id
    FROM account as a
    WHERE LOWER(a.username) = LOWER(from_user);
    
    -- Return empty if from_user not found
    IF from_account_id IS NULL THEN
      RETURN;
    END IF;
  END IF;

  -- Get account_id for to_user
  IF to_user IS NOT NULL THEN
    SELECT a.account_id INTO to_account_id
    FROM account as a
    WHERE LOWER(a.username) = LOWER(to_user);
    
    -- Return empty if to_user not found
    IF to_account_id IS NULL THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  WITH combined_tweets AS (
    SELECT 
      COALESCE(t.tweet_id,lt.tweet_id) as tweet_id,
      t.account_id,
      t.created_at,
      COALESCE(t.full_text, lt.full_text) as full_text,
      t.retweet_count,
      t.favorite_count,
      t.reply_to_user_id,
      t.reply_to_tweet_id,
      COALESCE(t.fts, lt.fts) as fts
    FROM (
      SELECT lt.tweet_id, lt.full_text, lt.fts
      FROM liked_tweets lt
      left JOIN likes l ON lt.tweet_id = l.liked_tweet_id 
      WHERE l.account_id = v_account_id
    ) lt
    LEFT JOIN tweets t ON lt.tweet_id = t.tweet_id
  ),
  matching_tweets AS (
    SELECT ct.tweet_id,ct.full_text
    FROM combined_tweets ct
    WHERE (search_query = '' OR ct.fts @@ websearch_to_tsquery('english', search_query))
      AND (from_account_id IS NULL OR ct.account_id = from_account_id)
      AND (to_account_id IS NULL OR ct.reply_to_user_id = to_account_id)
      AND (since_date IS NULL OR ct.created_at >= since_date OR ct.created_at IS NULL)
      AND (until_date IS NULL OR ct.created_at <= until_date OR ct.created_at IS NULL)
      AND (min_likes IS NULL OR ct.favorite_count >= min_likes OR ct.favorite_count IS NULL)
      AND (max_likes IS NULL OR ct.favorite_count <= max_likes OR ct.favorite_count IS NULL)
      AND (min_retweets IS NULL OR ct.retweet_count >= min_retweets OR ct.retweet_count IS NULL)
      AND (max_retweets IS NULL OR ct.retweet_count <= max_retweets OR ct.retweet_count IS NULL)
    ORDER BY COALESCE(ct.created_at, '2099-12-31'::timestamp) DESC
    LIMIT limit_
  )
  SELECT 
    COALESCE (mt.tweet_id,t.tweet_id), 
    t.account_id, 
    t.created_at, 
    COALESCE (mt.full_text,t.full_text), 
    t.retweet_count, 
    t.favorite_count,
    t.reply_to_tweet_id,
    p.avatar_media_url,
    p.archive_upload_id,
    a.username,
    a.account_display_name
  FROM matching_tweets mt
  LEFT JOIN tweets t ON mt.tweet_id = t.tweet_id
  LEFT JOIN account a ON t.account_id = a.account_id
  LEFT JOIN LATERAL (
    SELECT COALESCE(p.avatar_media_url,'none.com') as avatar_media_url, p.archive_upload_id
    FROM profile as p
    WHERE p.account_id = t.account_id
    ORDER BY p.archive_upload_id DESC
    LIMIT 1
  ) p ON true
  ORDER BY t.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION tes.search_tweets(
  search_query TEXT,
  from_user TEXT DEFAULT NULL,
  to_user TEXT DEFAULT NULL,
  since_date DATE DEFAULT NULL,
  until_date DATE DEFAULT NULL,
  min_likes INTEGER DEFAULT 0,
  min_retweets INTEGER DEFAULT 0,
  max_likes INTEGER DEFAULT 100000000,
  max_retweets INTEGER DEFAULT 100000000,
  limit_ INTEGER DEFAULT 50
)
RETURNS TABLE (
  tweet_id TEXT,
  account_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE,
  full_text TEXT,
  retweet_count INTEGER,
  favorite_count INTEGER,
  reply_to_tweet_id TEXT,
  avatar_media_url TEXT,
  archive_upload_id BIGINT,
  username TEXT,
  account_display_name TEXT
) AS $$
DECLARE
  from_account_id TEXT;
  to_account_id TEXT;
BEGIN
  -- Get account_id for from_user
  IF from_user IS NOT NULL THEN
    SELECT a.account_id INTO from_account_id
    FROM account as a
    WHERE LOWER(a.username) = LOWER(from_user);
    
    -- Return empty if from_user not found
    IF from_account_id IS NULL THEN
      RETURN;
    END IF;
  END IF;

  -- Get account_id for to_user
  IF to_user IS NOT NULL THEN
    SELECT a.account_id INTO to_account_id
    FROM account as a
    WHERE LOWER(a.username) = LOWER(to_user);
    
    -- Return empty if to_user not found
    IF to_account_id IS NULL THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  WITH matching_tweets AS (
    SELECT t.tweet_id
    FROM tweets t
    WHERE (search_query = '' OR t.fts @@ websearch_to_tsquery('english', search_query))
      AND (from_account_id IS NULL OR t.account_id = from_account_id)
      AND (to_account_id IS NULL OR t.reply_to_user_id = to_account_id)
      AND (since_date IS NULL OR t.created_at >= since_date)
      AND (until_date IS NULL OR t.created_at <= until_date)
      AND (min_likes IS NULL OR t.favorite_count >= min_likes)
      AND (max_likes IS NULL OR t.favorite_count <= max_likes)
      AND (min_retweets IS NULL OR t.retweet_count >= min_retweets)
      AND (max_retweets IS NULL OR t.retweet_count <= max_retweets)
    ORDER BY t.created_at DESC
    LIMIT limit_
  )
  SELECT 
    t.tweet_id, 
    t.account_id, 
    t.created_at, 
    t.full_text, 
    t.retweet_count, 
    t.favorite_count,
    t.reply_to_tweet_id,
    p.avatar_media_url,
    p.archive_upload_id,
    a.username,
    a.account_display_name
  FROM matching_tweets mt
  JOIN tweets t ON mt.tweet_id = t.tweet_id
  JOIN account a ON t.account_id = a.account_id
  LEFT JOIN LATERAL (
    SELECT p.avatar_media_url, p.archive_upload_id
    FROM profile as p
    WHERE p.account_id = t.account_id
    ORDER BY p.archive_upload_id DESC
    LIMIT 1
  ) p ON true
  ORDER BY t.created_at DESC;
END;
$$ LANGUAGE plpgsql;
