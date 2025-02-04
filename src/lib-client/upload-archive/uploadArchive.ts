import { Archive } from '../types'
import { processTwitterArchive } from '@/lib-client/db_insert'
import { uploadArchiveToStorage } from '@/lib-client/upload-archive/uploadArchiveToStorage'
import { SupabaseClient } from '@supabase/supabase-js'

export const uploadArchive = async (
  supabase: SupabaseClient,
  progressCallback: (progress: {
    phase: string
    percent: number | null
  }) => void,
  archive: Archive,
) => {
  progressCallback({ phase: 'Uploading archive', percent: 0 })

  // Use the new function here
  await uploadArchiveToStorage(supabase, archive)

  // Process the archive
  await processTwitterArchive(supabase, archive, progressCallback)
}
