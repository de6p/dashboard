summary_response="$(curl -sf -X POST "${BASE_URL}/api/trpc/dashboardRouter.getSummary" \
    -H "content-type: application/json" \
    -d '{"json":null}')"
if ! echo "${summary_response}" | grep -q '"totalJobs"'; then
    echo "dashboardRouter.getSummary did not return expected payload" >&2
    echo "${summary_response}" >&2
    exit 1
fi

queues_response="$(curl -sf -X POST "${BASE_URL}/api/trpc/queueRouter.getQueues" \
    -H "content-type: application/json" \
    -d '{"json":{"page":1,"pageSize":10}}')"
if ! echo "${queues_response}" | grep -q 'demo-'; then