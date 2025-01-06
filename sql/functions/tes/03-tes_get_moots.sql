DROP FUNCTION IF EXISTS tes_get_moots;

CREATE OR REPLACE FUNCTION tes_get_moots(user_id TEXT)
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
    f1.follower_account_id as account_id,
	mu.screen_name as username
    FROM public.followers f1
    INNER JOIN public.following f2 
        ON f1.account_id = f2.account_id 
        AND f1.follower_account_id = f2.following_account_id
	left join mentioned_users mu on mu.user_id = f1.follower_account_id
    where f1.account_id = $1;
END;
$$ LANGUAGE plpgsql;