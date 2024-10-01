// this doesn't work bc supabase needs cookies and I haven't figured out how to get that into a script but I'm leaving the file as an example
import * as dotenv from 'dotenv'
import path from 'path'
import { createClient } from '@supabase/supabase-js'
import fs from 'fs'
import { fileURLToPath } from 'url'
const { processTwitterArchive } = await import('../src/lib-server/db_insert')

// Get the directory name of the current module
const __filename = fileURLToPath(import.meta.url)

// Load environment variables
// dotenv.config({ path: path.resolve(__dirname, '../.env.local') })

// const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const supabaseUrl = process.env.NEXT_PUBLIC_LOCAL_SUPABASE_URL
// const supabaseServiceRoleKey = process.env.SUPABASE_SERVICE_ROLE
// const supabaseServiceRoleKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
const supabaseServiceRoleKey = process.env.NEXT_PUBLIC_LOCAL_SERVICE_ROLE
console.log('supabaseUrl', supabaseUrl)
console.log('supabaseServiceRoleKey', supabaseServiceRoleKey)
console.log(
  'NEXT_PUBLIC_USE_REMOTE_DEV_DB',
  process.env.NEXT_PUBLIC_USE_REMOTE_DEV_DB,
)

if (!supabaseUrl || !supabaseServiceRoleKey) {
  console.error(
    'Missing Supabase URL or service role key in environment variables',
  )
  process.exit(1)
}

// Create Supabase client directly
const supabase = createClient(supabaseUrl, supabaseServiceRoleKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
  global: {
    headers: {
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
    },
  },
})

async function uploadArchive(filePath: string) {
  try {
    const archiveData = JSON.parse(fs.readFileSync(filePath, 'utf8'))
    console.log('archiveData', archiveData.account)
    await processTwitterArchive(supabase, archiveData, (progress) => {
      console.log(`${progress.phase}: ${progress.percent?.toFixed(2)}%`)
    })

    console.log('Archive upload completed successfully')
  } catch (error) {
    console.error('Error uploading archive:', error)
  }
}

// Check if a file path is provided as a command-line argument
const archiveFilePath = process.argv[2]
if (!archiveFilePath) {
  console.error(
    'Please provide the path to the archive JSON file as an argument',
  )
  process.exit(1)
}
console.log('uploading archive', archiveFilePath)

uploadArchive(archiveFilePath)

// const visa_account1 = {
//   createdVia: 'web',
//   username: 'visakanv',
//   accountId: '16884623',
//   createdAt: '2008-10-21T12:01:00.000Z',
//   accountDisplayName: 'Visakan Veerasamy',
//   num_tweets: 53999,
//   num_following: 2376,
//   num_followers: 88695,
//   num_likes: 340061,
// }
// const visa_account = {
//   created_via: 'web',
//   username: 'visakanv',
//   account_id: '16884623',
//   created_at: '2008-10-21T12:01:00.000Z',
//   account_display_name: 'Visakan Veerasamy',
//   num_tweets: 53999,
//   num_following: 2376,
//   num_followers: 88695,
//   num_likes: 340061,
// }
// const suffix = '16884623'
// supabase
//   .schema('public')
//   .rpc('create_temp_tables', { p_suffix: suffix })
//   .then(() => {
//     supabase
//       .schema('temp')
//       .from(`likes_${suffix}`)
//       .select('*')
//       .then(() => {
//         supabase
//           .schema('public')
//           .rpc('insert_temp_account', {
//             p_account: visa_account1,
//             p_suffix: '16884623',
//           })
//           .then((res) => {
//             console.log('insert_temp_account', res)
//           })
//       })
//   })

// supabase
//   .schema('public')
//   .from('account')
//   .upsert(visa_account)
//   .then((res) => {
//     console.log('upsert', res)
//   })
