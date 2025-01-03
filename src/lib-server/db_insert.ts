import { devLog } from '@/lib-client/devLog'
import { Archive } from '@/lib-client/types'
import { SupabaseClient } from '@supabase/supabase-js'
import dotenv from 'dotenv'
import path from 'path'

// Load environment variables from .env file in the scratchpad directory
if (process.env.NODE_ENV !== 'production') {
  dotenv.config({ path: path.resolve(__dirname, '../../.env.local') })
}

const BATCH_SIZE = 1000 // Adjust as needed

const MAX_RETRIES = 5
const RETRY_DELAY = 1000 // 1 second

export const retryOperation = async <T>(
  operation: () => Promise<T>,
  errorMessage: string,
): Promise<T> => {
  let retries = 0
  while (retries < MAX_RETRIES) {
    try {
      return await operation()
    } catch (error) {
      retries++
      if (retries >= MAX_RETRIES) {
        throw new Error(`${errorMessage}: ${(error as Error).message}`)
      }
      console.log(`Attempt ${retries} failed. Retrying in ${RETRY_DELAY}ms...`)
      console.info(`${errorMessage}: ${(error as Error).message}`)
      await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY))
    }
  }
  throw new Error(`Max retries reached for operation: ${errorMessage}`)
}

const patchTweetsWithNoteTweets = (noteTweets: any[], tweets: any[]): any[] => {
  const startTime = performance.now()
  // console.log('noteTweets', { noteTweets })

  const patchedTweets = tweets.map((tweetObj) => {
    const tweet = tweetObj.tweet
    const matchingNoteTweet = noteTweets.find((noteTweetObj) => {
      const noteTweet = noteTweetObj.noteTweet
      return (
        tweet.full_text.includes(noteTweet.core.text.substring(0, 200)) &&
        Math.abs(
          new Date(tweet.created_at).getTime() -
            new Date(noteTweet.createdAt).getTime(),
        ) < 1000
      )
    })

    if (matchingNoteTweet) {
      return {
        ...tweetObj,
        tweet: {
          ...tweet,
          full_text: matchingNoteTweet.noteTweet.core.text,
        },
      }
    }

    return tweetObj
  })

  const endTime = performance.now()
  console.log(`Patching tweets with note tweets took ${endTime - startTime} ms`)

  // console.log('Changed tweets:', changedTweets)

  return patchedTweets
}

const insertTempTweets = async (
  supabase: SupabaseClient,
  tweets: any[],
  suffix: string,
) => {
  const formattedTweets = tweets.map((tweet) => ({
    tweet_id: tweet.id_str,
    account_id: tweet.user_id,
    created_at: tweet.created_at,
    full_text: tweet.full_text,
    retweet_count: tweet.retweet_count,
    favorite_count: tweet.favorite_count,
    reply_to_tweet_id: tweet.in_reply_to_status_id_str,
    reply_to_user_id: tweet.in_reply_to_user_id_str,
    reply_to_username: tweet.in_reply_to_screen_name,
    archive_upload_id: -1, // Placeholder value
  }))

  await retryOperation(async () => {
    const { data, error } = await supabase
      .schema('temp')
      .from(`tweets_${suffix}`)
      .upsert(formattedTweets, {
        onConflict: 'tweet_id',
        ignoreDuplicates: false,
      })
    if (error) throw error
    return data
  }, 'Error inserting tweets')
}

const processAndInsertTweetEntities = async (
  supabase: SupabaseClient,
  tweets: any[],
  suffix: string,
) => {
  const mentionedUsers = Object.values(
    tweets
      .flatMap((tweet) =>
        tweet.entities.user_mentions.reduce((acc: any, user: any) => {
          acc[user.id_str] = {
            user_id: user.id_str,
            name: user.name,
            screen_name: user.screen_name,
            updated_at: new Date().toISOString(),
          }
          return acc
        }, {}),
      )
      .reduce((acc: any, curr: any) => {
        Object.assign(acc, curr)
        return acc
      }, {}),
  )

  const userMentions = tweets.flatMap((tweet) =>
    tweet.entities.user_mentions.map((user: any) => ({
      mentioned_user_id: user.id_str,
      tweet_id: tweet.id_str,
    })),
  )

  const tweetMedia = tweets.flatMap((tweet) =>
    (tweet.entities.media || []).map((media: any) => ({
      media_id: media.id_str,
      tweet_id: tweet.id_str,
      media_url: media.media_url_https,
      media_type: media.type,
      width: media.sizes.large.w,
      height: media.sizes.large.h,
      archive_upload_id: -1, // Placeholder value
    })),
  )

  const tweetUrls = tweets.flatMap((tweet) =>
    tweet.entities.urls.map((url: any) => ({
      url: url.url,
      expanded_url: url.expanded_url,
      display_url: url.display_url,
      tweet_id: tweet.id_str,
    })),
  )

  const tables = [
    {
      name: `mentioned_users_${suffix}`,
      data: mentionedUsers,
      conflictTarget: 'user_id',
    },
    {
      name: `user_mentions_${suffix}`,
      data: userMentions,
      conflictTarget: 'mentioned_user_id, tweet_id',
    },
    {
      name: `tweet_media_${suffix}`,
      data: tweetMedia,
      conflictTarget: 'media_id',
    },
    {
      name: `tweet_urls_${suffix}`,
      data: tweetUrls,
      conflictTarget: 'url, tweet_id',
    },
  ]

  for (const table of tables) {
    for (let i = 0; i < table.data.length; i += 1000) {
      const batch = table.data.slice(i, i + 1000)
      await retryOperation(async () => {
        const { data, error } = await supabase
          .schema('temp')
          .from(table.name)
          .upsert(batch, {
            onConflict: table.conflictTarget,
            ignoreDuplicates: true,
          })
        if (error) throw error
        return data
      }, `Error inserting ${table.name}`)
    }
  }
}

const insertTempFollowers = async (
  supabase: SupabaseClient,
  followers: any[],
  accountId: string,
  suffix: string,
) => {
  const formattedFollowers = followers.map((follower) => ({
    account_id: accountId,
    follower_account_id: follower.follower.accountId,
    archive_upload_id: -1, // Placeholder value
  }))

  await retryOperation(async () => {
    const { data, error } = await supabase
      .schema('temp')
      .from(`followers_${suffix}`)
      .upsert(formattedFollowers, {
        onConflict: 'account_id,follower_account_id',
        ignoreDuplicates: false,
      })
    if (error) throw error
    return data
  }, 'Error inserting followers')
}

const insertTempFollowing = async (
  supabase: SupabaseClient,
  following: any[],
  accountId: string,
  suffix: string,
) => {
  const formattedFollowing = following.map((follow) => ({
    account_id: accountId,
    following_account_id: follow.following.accountId,
    archive_upload_id: -1, // Placeholder value
  }))

  await retryOperation(async () => {
    const { data, error } = await supabase
      .schema('temp')
      .from(`following_${suffix}`)
      .upsert(formattedFollowing, {
        onConflict: 'account_id,following_account_id',
        ignoreDuplicates: false,
      })
    if (error) throw error
    return data
  }, 'Error inserting following')
}

const insertTempLikes = async (
  supabase: SupabaseClient,
  likes: any[],
  accountId: string,
  suffix: string,
) => {
  const likedTweets = likes.map((like) => ({
    tweet_id: like.like.tweetId,
    full_text: like.like.fullText,
  }))

  // Ensure all likes have non-null full_text
  const validLikedTweets = likedTweets.map((like) => ({
    ...like,
    full_text: like.full_text || '',
  }))

  await retryOperation(async () => {
    const { data, error } = await supabase
      .schema('temp')
      .from(`liked_tweets_${suffix}`)
      .upsert(validLikedTweets, {
        onConflict: 'tweet_id',
        ignoreDuplicates: false,
      })
    if (error) throw error
    return data
  }, 'Error inserting liked tweets')

  const likeRelations = likes.map((like) => ({
    account_id: accountId,
    liked_tweet_id: like.like.tweetId,
    archive_upload_id: -1, // Placeholder value
  }))

  await retryOperation(async () => {
    const { data, error } = await supabase
      .schema('temp')
      .from(`likes_${suffix}`)
      .upsert(likeRelations, {
        onConflict: 'account_id,liked_tweet_id',
        ignoreDuplicates: false,
      })
    if (error) throw error
    return data
  }, 'Error inserting likes')
}

export const processTwitterArchive = async (
  supabase: SupabaseClient,
  archiveData: Archive,
  progressCallback: (progress: {
    phase: string
    percent: number | null
  }) => void,
): Promise<void> => {
  const startTime = performance.now()
  console.log('Starting Twitter Archive processing...')
  devLog('archiveData', { archiveData })

  const accountId = archiveData.account[0].account.accountId
  const suffix = accountId

  console.log('Dropping temporary tables...')
  await retryOperation(async () => {
    const { data, error } = await supabase
      .schema('public')
      .rpc('drop_temp_tables', {
        p_suffix: suffix,
      })
    if (error) throw error
    return data
  }, 'Error dropping temporary tables')

  try {
    // Calculate latest tweet date
    const latestTweetDate = archiveData.tweets.reduce(
      (latest: string, tweet: any) => {
        const tweetDate = new Date(tweet.tweet.created_at)
        return latest
          ? tweetDate > new Date(latest)
            ? tweetDate.toISOString()
            : latest
          : tweetDate.toISOString()
      },
      '',
    )

    console.log(`Latest tweet date: ${latestTweetDate}`)

    // Create temporary tables
    console.log('Creating temporary tables...')
    await retryOperation(async () => {
      const { data, error } = await supabase
        .schema('public')
        .rpc('create_temp_tables', {
          p_suffix: suffix,
        })
      if (error) throw error
      return data
    }, 'Error creating temporary tables')

    // Verify tables are created
    await retryOperation(async () => {
      const { data, error } = await supabase
        .schema('temp')
        .from(`likes_${suffix}`)
        .select('*')
      if (error) throw error
      return data
    }, 'Failed to verify temporary tables')

    // Compute counts
    const num_tweets = archiveData.tweets.length
    const num_following = archiveData.following
      ? archiveData.following.length
      : 0
    const num_followers = archiveData.follower ? archiveData.follower.length : 0
    const num_likes = archiveData.like ? archiveData.like.length : 0

    console.log('Inserting account data...', {
      ...archiveData.account[0].account,
      num_tweets,
      num_following,
      num_followers,
      num_likes,
    })

    await retryOperation(async () => {
      const { data, error } = await supabase
        .schema('public')
        .rpc('insert_temp_account', {
          p_account: {
            ...archiveData.account[0].account,
            num_tweets,
            num_following,
            num_followers,
            num_likes,
          },
          p_suffix: suffix,
        })
      if (error) throw error
      return data
    }, 'Error inserting account data')

    console.log('Inserting archive upload data...')
    const { data: archiveUploadId } = await retryOperation(async () => {
      const uploadOptions = archiveData['upload-options'] || {
        keepPrivate: false,
        uploadLikes: true,
        startDate: null,
        endDate: null,
      }
      const { data, error } = await supabase
        .schema('public')
        .rpc('insert_temp_archive_upload', {
          p_account_id: accountId,
          p_archive_at: latestTweetDate,
          p_keep_private: uploadOptions.keepPrivate,
          p_upload_likes: uploadOptions.uploadLikes,
          p_start_date: uploadOptions.startDate,
          p_end_date: uploadOptions.endDate,
          p_suffix: suffix,
        })
      if (error) throw error
      return data
    }, 'Error inserting archive upload data')

    console.log('Inserting profile data...')
    await retryOperation(async () => {
      const { data, error } = await supabase
        .schema('public')
        .rpc('insert_temp_profiles', {
          p_profile: archiveData.profile[0].profile,
          p_account_id: accountId,
          p_suffix: suffix,
        })
      if (error) throw error
      return data
    }, 'Error inserting profile data')

    // Patch tweets with note tweets
    console.log('Patching tweets with note tweets...')
    const patchedTweets = patchTweetsWithNoteTweets(
      archiveData['note-tweet'] || [],
      archiveData.tweets,
    )
    // console.log('patchedTweets', { patchedTweets })
    // Process likes
    console.log('Processing likes...')
    const likesStartTime = Date.now()
    const totalLikes = archiveData.like.length
    for (let i = 0; i < totalLikes; i += BATCH_SIZE) {
      const likesBatch = archiveData.like.slice(i, i + BATCH_SIZE)
      console.log(`Processing likes batch ${i / BATCH_SIZE + 1}...`)
      await insertTempLikes(supabase, likesBatch, accountId, suffix)
      progressCallback({
        phase: 'Likes',
        percent: Math.min(100, ((i + BATCH_SIZE) / totalLikes) * 100),
      })
    }
    const likesEndTime = Date.now()
    console.log(`Likes processing time: ${likesEndTime - likesStartTime}ms`)

    // Process tweets
    console.log('Processing tweets...')
    const tweetsStartTime = Date.now()
    const totalTweets = patchedTweets.length
    for (let i = 0; i < totalTweets; i += BATCH_SIZE) {
      const tweetsBatch = patchedTweets.slice(i, i + BATCH_SIZE)
      console.log(`Processing tweets batch ${i / BATCH_SIZE + 1}...`)
      await insertTempTweets(
        supabase,
        tweetsBatch.map((t: any) => ({ ...t.tweet, user_id: accountId })),
        suffix,
      )
      await processAndInsertTweetEntities(
        supabase,
        tweetsBatch.map((t: any) => t.tweet),
        suffix,
      )
      progressCallback({
        phase: 'Tweets',
        percent: Math.min(100, ((i + BATCH_SIZE) / totalTweets) * 100),
      })
    }
    const tweetsEndTime = Date.now()
    console.log(`Tweets processing time: ${tweetsEndTime - tweetsStartTime}ms`)

    // Process followers
    console.log('Processing followers...')
    const followsStartTime = Date.now()
    const totalFollowers = archiveData.follower.length
    for (let i = 0; i < totalFollowers; i += BATCH_SIZE) {
      const followersBatch = archiveData.follower.slice(i, i + BATCH_SIZE)
      console.log(`Processing followers batch ${i / BATCH_SIZE + 1}...`)
      await insertTempFollowers(supabase, followersBatch, accountId, suffix)
      progressCallback({
        phase: 'Followers',
        percent: Math.min(100, ((i + BATCH_SIZE) / totalFollowers) * 100),
      })
    }

    // Process following
    console.log('Processing following...')
    const totalFollowing = archiveData.following.length
    for (let i = 0; i < totalFollowing; i += BATCH_SIZE) {
      const followingBatch = archiveData.following.slice(i, i + BATCH_SIZE)
      console.log(`Processing following batch ${i / BATCH_SIZE + 1}...`)
      await insertTempFollowing(supabase, followingBatch, accountId, suffix)
      progressCallback({
        phase: 'Following',
        percent: Math.min(100, ((i + BATCH_SIZE) / totalFollowing) * 100),
      })
    }
    const followsEndTime = Date.now()
    console.log(
      `Follows processing time: ${followsEndTime - followsStartTime}ms`,
    )

    // Commit all data
    console.log('Committing all data...')
    progressCallback({
      phase: 'Finishing up...',
      percent: null,
    })
    try {
      const commitStartTime = Date.now()
      await retryOperation(async () => {
        const { data, error } = await supabase
          .schema('public')
          .rpc('commit_temp_data', {
            p_suffix: suffix,
          })
        if (error) throw error
        return data
      }, 'Error committing data')
      const commitEndTime = Date.now()
      console.log(
        `Commit processing time: ${commitEndTime - commitStartTime}ms`,
      )
    } catch (error: any) {
      console.error('Error processing Twitter archive:', error)
    }

    console.log('Twitter archive processing completed successfully.')
    progressCallback({
      phase: 'Archive Uploaded',
      percent: 100,
    })
    const endTime = performance.now()
    const totalTimeInSeconds = (endTime - startTime) / 1000
    console.log(
      `Total archive upload time: ${totalTimeInSeconds.toFixed(2)} seconds`,
    )
  } catch (error: any) {
    console.error('Error processing Twitter archive:', error)

    // Attempt to drop temporary tables
    try {
      console.log('Attempting to drop temporary tables...')
      await retryOperation(async () => {
        const { data, error } = await supabase
          .schema('public')
          .rpc('drop_temp_tables', {
            p_suffix: suffix,
          })
        if (error) throw error
        return data
      }, 'Error dropping temporary tables')
      console.log('Temporary tables dropped successfully.')
    } catch (dropError: any) {
      console.error('Error dropping temporary tables:', dropError)
    }

    // Throw a new error with more context
    throw new Error(`Error processing Twitter archive: ${error.message}`)
  }
  try {
    console.log('Attempting to drop temporary tables...')
    await retryOperation(async () => {
      const { data, error } = await supabase
        .schema('public')
        .rpc('drop_temp_tables', {
          p_suffix: suffix,
        })
      if (error) throw error
      return data
    }, 'Error dropping temporary tables')
    console.log('Temporary tables dropped successfully.')
  } catch (dropError: any) {
    console.error('Error dropping temporary tables:', dropError)
  }
}

export const deleteArchive = async (
  supabase: SupabaseClient,
  accountId: string,
): Promise<void> => {
  try {
    const { error } = await supabase
      .schema('public')
      .rpc('delete_all_archives', {
        p_account_id: accountId,
      })

    if (error) throw error

    console.log(`All archives for account ${accountId} deleted successfully`)
  } catch (error: any) {
    throw new Error(
      `Error deleting archives of account ${accountId}: ${error.message}`,
    )
  }
}
