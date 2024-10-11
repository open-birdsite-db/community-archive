# What data from the archive do we use?

We only use and store the following files from the archive.

If you want to be 100% sure abot your privacy, you can remvove everything else from the data folder.

| File               | Contains                                               | Why We Need                                        |
| ------------------ | ------------------------------------------------------ | -------------------------------------------------- |
| tweets.js          | Tweet data, including text, timestamps, and metadata   | Core content for user's timeline                   |
| following.js       | List of accounts user follows                          | Show user's network, interests                     |
| follower.js        | List of accounts following user                        | Show user's influence, popularity                  |
| account.js         | Basic account info like email, username, creation date | Identify user, show account age                    |
| profile.js         | User's profile data like bio, location, avatar         | Display user info in UI                            |
| note-tweet.js      | Full text of long tweets                               | Complete content for tweets truncated in tweets.js |
| like.js (optional) | Tweets user has liked                                  | Show user's interests, engagement                  |

## Examples

tweets.js:

```json
window.YTD.tweets.part1 = [
  {
    "tweet" : {
      "edit_info" : {
        "initial" : {
          "editTweetIds" : [
            "1626922779105759235"
          ],
          "editableUntil" : "2023-02-18T13:03:11.000Z",
          "editsRemaining" : "5",
          "isEditEligible" : false
        }
      },
      "retweeted" : false,
      "source" : "<a href=\"https://mobile.twitter.com\" rel=\"nofollow\">Twitter Web App</a>",
      "entities" : {
        "hashtags" : [ ],
        "symbols" : [ ],
        "user_mentions" : [
          {
            "name" : "Cameron (🇵🇹)",
            "screen_name" : "empathy2000",
            "indices" : [
              "0",
              "12"
            ],
            "id_str" : "732980797985148928",
            "id" : "732980797985148928"
          }
        ],
        "urls" : [ ]
      },
      "display_text_range" : [
        "0",
        "71"
      ],
      "favorite_count" : "1",
      "in_reply_to_status_id_str" : "1626916612560281601",
      "id_str" : "1626922779105759235",
      "in_reply_to_user_id" : "732980797985148928",
      "truncated" : false,
      "retweet_count" : "0",
      "id" : "1626922779105759235",
      "in_reply_to_status_id" : "1626916612560281601",
      "created_at" : "Sat Feb 18 12:33:11 +0000 2023",
      "favorited" : false,
      "full_text" : "@empathy2000 did NOT know but now I'm listening to her solo act bc of u",
      "lang" : "en",
      "in_reply_to_screen_name" : "empathy2000",
      "in_reply_to_user_id_str" : "732980797985148928"
    }
  }
```

following.js:

```json
window.YTD.following.part0 = [
  {
    "following" : {
      "accountId" : "824308056351735809",
      "userLink" : "https://twitter.com/intent/user?user_id=824308056351735809"
    }
  },
  {
    "following" : {
      "accountId" : "18969923",
      "userLink" : "https://twitter.com/intent/user?user_id=18969923"
    }
  },
  {
    "following" : {
      "accountId" : "3297675443",
      "userLink" : "https://twitter.com/intent/user?user_id=3297675443"
    }
  }
]
```

follower.js:

```json
window.YTD.follower.part0 = [
  {
    "follower" : {
      "accountId" : "1252851",
      "userLink" : "https://twitter.com/intent/user?user_id=1252851"
    }
  },
  {
    "follower" : {
      "accountId" : "1310630474755178496",
      "userLink" : "https://twitter.com/intent/user?user_id=1310630474755178496"
    }
  },
  {
    "follower" : {
      "accountId" : "1265789414023651328",
      "userLink" : "https://twitter.com/intent/user?user_id=1265789414023651328"
    }
  }
]
```

account.js:

We don't keep your email in the db.

```json
window.YTD.account.part0 = [
  {
    "account" : {
      "email" : "theexgenesis@gmail.com",
      "createdVia" : "web",
      "username" : "exGenesis",
      "accountId" : "322603863",
      "createdAt" : "2011-06-23T13:04:14.000Z",
      "accountDisplayName" : "❤️‍🔥 xiq"
    }
  }
]
```

profile.js:

```json
window.YTD.profile.part0 = [
  {
    "profile" : {
      "description" : {
        "bio" : "Grug's bio here",
        "website" : "https://grug.com",
        "location" : "Cave"
      },
      "avatarMediaUrl" : "https://pbs.twimg.com/profile_images/grug.jpg",
      "headerMediaUrl" : "https://pbs.twimg.com/profile_banners/grug_banner.jpg"
    }
  }
]
```

note-tweet.js:

```json
window.YTD.note_tweet.part0 = [
  {
    "noteTweet" : {
      "noteTweetId" : "1234567890",
      "noteTweetResults" : {
        "text" : "This is a long tweet by Grug. It goes over 280 characters so it's stored here.",
        "entitySet" : {
          "hashtags" : [ ],
          "symbols" : [ ],
          "userMentions" : [ ],
          "urls" : [ ]
        }
      },
      "tweetId" : "9876543210"
    }
  }
]
```

like.js:

```json
window.YTD.like.part1 = [
  {
    "like" : {
      "tweetId" : "16270389803521472158",
      "fullText" : "They're so flat they're almost completely clear, except when the light catches them just right. You can read more in an article I wrote about them here: https://t.co/BhS444jEkF https://t.co/iFeHiZZdUn",
      "expandedUrl" : "https://twitter.com/i/web/status/1627038980352147458"
    }
  },
  {
    "like" : {
      "tweetId" : "16270386918259250720",
      "fullText" : "Sea sapphires are some of the most beautiful animals on Earth.\nTheir bodies contain microscopic crystals that reflect blue light. They use this shine in courtship displays, &amp; in Japan, fishers call this tama-mizu: jeweled water.\n📽️ https://t.co/NI2DioTKA4\nhttps://t.co/Koww4X3sXB",
      "expandedUrl" : "https://twitter.com/i/web/status/1627038691825950720"
    }
  },
  {
    "like" : {
      "tweetId" : "16270394452530201219",
      "fullText" : "https://t.co/erVoNQELZ2",
      "expandedUrl" : "https://twitter.com/i/web/status/1627039445253001219"
    }
  }
]
```
