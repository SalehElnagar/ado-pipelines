import { processJobs } from './worker.js';

describe('worker-service', () => {
  it('processes jobs into upper-case output', () => {
    const input = ['a', 'b'];
    const result = processJobs(input);
    expect(result).toHaveLength(2);
    expect(result[0].output).toBe('A');
    expect(result[1].output).toBe('B');
  });

  it('handles empty jobs gracefully', () => {
    const result = processJobs([]);
    expect(result).toEqual([]);
  });
});
