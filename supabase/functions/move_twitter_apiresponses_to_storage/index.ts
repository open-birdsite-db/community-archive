import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from 'jsr:@supabase/supabase-js@2'

const STORAGE_URL = `${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/twitter_api_files`

Deno.serve(async (req) => {
  const startTime = performance.now();
  let supabaseAdminClient: ReturnType<typeof createClient> | null = null;
  
  try {
    // Validate environment variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    
    if (!supabaseUrl || !supabaseKey) {
      throw new Error("Missing required environment variables");
    }

    supabaseAdminClient = createClient(supabaseUrl, supabaseKey);
    
    // Test the connection
    const { data: testData, error: testError } = await supabaseAdminClient.from("temporary_data").select("count").limit(1);
    if (testError) {
      throw new Error(`Database connection test failed: ${testError.message}`);
    }

    const { data, error } = await supabaseAdminClient.storage.from("twitter_api_files").list();
    if (error) {
      throw new Error(`Storage error: ${error.message}`);
    }

    const bucketName = "twitter_api_files";
    const res = await move_twitter_apiresponses_to_storage(supabaseAdminClient, bucketName);

    return new Response(
      JSON.stringify(res),
      { 
        headers: { 
          "Content-Type": "application/json",
          "X-Execution-Time": `${performance.now() - startTime}ms`
        } 
      },
    );

  } catch (e) {
    console.error('Function error:', e);
    
    return new Response(
      JSON.stringify({ 
        error: e instanceof Error ? e.message : 'Unknown error occurred',
        timestamp: new Date().toISOString()
      }), 
      { 
        status: 500,
        headers: { 
          "Content-Type": "application/json",
          "X-Execution-Time": `${performance.now() - startTime}ms`
        }
      }
    );
  } 
});

export async function move_twitter_apiresponses_to_storage(
  supabase: ReturnType<typeof createClient>,
  bucketName: string,
  batchSize: number = 150
): Promise<{ success: boolean; processedCount?: number; error?: any }> {
  try {
    const { data: tempRecords, error: fetchError } = await supabase
      .from('temporary_data')
      .select('*')
      .not('inserted','is', null)
      .eq('stored', false)
      .like('type', 'api_%')
      .limit(batchSize);

    if (fetchError) throw fetchError;
    if (!tempRecords || tempRecords.length === 0) {
      return { success: true, processedCount: 0 };
    }

    let processedCount = 0;

    for (const record of tempRecords) {
      try {
        const filename = `${record.originator_id}/${record.timestamp}__${record.type}.json`;
        
        // Upload file with explicit error handling
        const { error: uploadError } = await supabase.storage
          .from(bucketName)
          .upload(filename, JSON.stringify(record.data), {
            contentType: 'application/json',
            upsert: true
          });

        if (uploadError) throw uploadError;

        // Update record status with explicit error handling
        const { error: updateError } = await supabase
          .from('temporary_data')
          .update({ stored: true })
          .eq('type', record.type)
          .eq('originator_id', record.originator_id)
          .eq('item_id', record.item_id)
          .eq('timestamp', record.timestamp);

        if (updateError) throw updateError;

        processedCount++;
      } catch (recordError) {
        console.error(`Error processing record ${record.id}:`, recordError);
        // Continue with next record instead of failing completely
        continue;
      }
    }
    console.log("processedCount",processedCount)
    return { success: true, processedCount };
    
  } catch (error) {
    console.error('Error in processTemporaryData:', error);
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Unknown error in data processing',
      processedCount: 0
    };
  }
}