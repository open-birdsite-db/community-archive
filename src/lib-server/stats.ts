import { createServerClient } from '@/utils/supabase'
import { cookies } from 'next/headers'
import { SupabaseClient } from '@supabase/supabase-js'

export const getStats = async (supabase: SupabaseClient) => {
  const { data, error } = await supabase
    .schema('public')
    .from('global_activity_summary')
    .select('total_accounts, total_tweets, total_likes, total_user_mentions')
    .single()

  if (error) {
    console.error('Error fetching global activity summary:', error)
    throw error
  }

  return {
    accountCount: data.total_accounts,
    tweetCount: data.total_tweets,
    likedTweetCount: data.total_likes,
    userMentionsCount: data.total_user_mentions,
  }
}
