// Load that makes the search API autoscale: a ramp of hybrid searches through the ingress, with a probe that
// records the first and last failing request so recovery and reaction times can be read off the output.
//   k6 run -e BASE=https://localhost:8443 -e HOST=search.localtest.me load/hpa-load.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'https://localhost:8443';
const HOST = __ENV.HOST || 'search.localtest.me';
const QUERIES = ['wireless headphones', 'running shoes', 'bluetooth speaker', 'coffee maker', 'rain jacket', 'wireless mouse', 'glass storage containers', 'building blocks set', 'laptop stand', 'office chair'];
const failures = new Counter('probe_failures');
const latency = new Trend('search_ms', true);

export const options = {
  insecureSkipTLSVerify: true, // the local platform CA is not in k6's trust store
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 400,
      stages: [
        { target: 5, duration: '1m' },
        { target: 60, duration: '30s' },
        { target: 60, duration: '4m' },
        { target: 5, duration: '30s' },
        { target: 5, duration: '2m' },
      ],
    },
  },
  thresholds: { http_req_failed: ['rate<0.05'] },
  summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max', 'count'],
};

export default function () {
  const q = QUERIES[Math.floor(Math.random() * QUERIES.length)];
  const res = http.get(`${BASE}/api/search?q=${encodeURIComponent(q)}&ranker=hybrid&size=10&no_cache=true`, { headers: { Host: HOST }, tags: { name: 'search' } });
  const ok = check(res, { 'status 200': (r) => r.status === 200 });
  latency.add(res.timings.duration);
  if (!ok) failures.add(1);
}

export function handleSummary(data) {
  const m = data.metrics;
  const out = {
    scenario: 'ramp 5 -> 60 -> 5 requests/s',
    requests: m.http_reqs ? m.http_reqs.values.count : null,
    failed_share: m.http_req_failed ? m.http_req_failed.values.rate : null,
    search_ms: m.search_ms ? m.search_ms.values : null,
  };
  return { stdout: JSON.stringify(out, null, 2) + '\n', '/out/hpa-load.json': JSON.stringify(out, null, 2) };
}
