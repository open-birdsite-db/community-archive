import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from 'jsr:@supabase/supabase-js@2'


Deno.serve(async (req: Request) => {
  const startTime = performance.now();
  let supabaseAdminClient: ReturnType<typeof createClient> | null = null;
  const results = [];

  try {
    // Validate environment variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    
    if (!supabaseUrl || !supabaseKey) {
      throw new Error("Missing required environment variables");
    }

    supabaseAdminClient = createClient(supabaseUrl, supabaseKey);

    const invokeFunction = async () => {
      const { data, error } = await supabaseAdminClient.functions.invoke('move_twitter_apiresponses_to_storage', {
        method: 'POST'
      });
      
      if (error) throw error;
      return data;
    };

    const INVOCATIONS = 5;
    const WAIT_BETWEEN_INVOCATIONS = 10000;
   
    for(let i = 0; i < INVOCATIONS; i++){
        let res = await invokeFunction();
        if(!res.success){
          console.log(`invocation ${i+1} failed. ${JSON.stringify(res)}`); 
          throw new Error(`invocation ${i+1} failed. ${JSON.stringify(res)}`);
          break;
        }
        else if (res.processedCount == 0) {
          console.log(`invocation ${i+1} has no data to process. ${JSON.stringify(res)}`); 
          break;
        }
        results.push(res);
        

        if(i < INVOCATIONS - 1) await new Promise(resolve => setTimeout(resolve, WAIT_BETWEEN_INVOCATIONS));
    }
    
    console.log("schedule took ",performance.now() - startTime,"ms")
    console.log("results",JSON.stringify(results))
    return new Response(
      JSON.stringify({ 
        results: results.reduce((acc, curr) => acc + curr.processedCount, 0),
        totalExecutionTime: `${performance.now() - startTime}ms`
      }),
      { 
        headers: { 
          "Content-Type": "application/json",
          "X-Execution-Time": `${performance.now() - startTime}ms`
        } 
      },
    );

  } catch (e) {
    console.error('Function error:', e);
    const endTime = performance.now();
    return new Response(
      JSON.stringify({ 
        error: e instanceof Error ? e.message : 'Unknown error occurred',
        timestamp: new Date().toISOString()
      }), 
      { 
        status: 500,
        headers: { 
          "Content-Type": "application/json",
          "X-Execution-Time": `${endTime - startTime}ms`
        }
      }
    );
  } 
});
