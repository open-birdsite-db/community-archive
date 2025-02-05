CREATE INDEX IF NOT EXISTS tweets_account_id_retweet_idx ON public.tweets(account_id, retweet_count DESC);
CREATE INDEX IF NOT EXISTS tweets_account_id_favorite_idx ON public.tweets(account_id, favorite_count DESC);
CREATE INDEX IF NOT EXISTS tweets_engagement_idx ON public.tweets(account_id, (retweet_count + favorite_count) DESC);