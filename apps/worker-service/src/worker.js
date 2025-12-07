export function processJobs(jobs = []) {
  const processed = jobs.map((job, idx) => ({
    id: idx,
    input: job,
    output: String(job).toUpperCase()
  }));
  return processed;
}

if (process.env.RUN_WORKER === 'true') {
  const inputs = (process.env.JOBS || 'alpha,beta').split(',');
  const result = processJobs(inputs);
  console.log(JSON.stringify({ processed: result }));
}
