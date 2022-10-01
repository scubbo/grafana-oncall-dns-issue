This repo replicates an issue I'm running into with DNS resolution from Grafana Oncall's Outgoing Webhooks.

# TL;DR

DNS resolution when calling a webhook does not appear to be able to resolve a) Kubernetes Service DNS names, or b) DNS names defined on a LAN's DNS server. Since resolution succeeds for "publicly" defined DNS names (that is - those served by a DNS server on the public Internet), I suspect this means that webhook resolution is using a hard-coded DNS server (e.g. `1.1.1.1` or `8.8.8.8`) rather than the configuration in `/etc/resolv.conf` (which seems to be used, as expected, for `wget`/`nslookup` from the Engine pod) - but I don't know enough about either DNS debugging, or the internals of Oncall, to be able to confirm this.

## Why does this matter?

I'm trying to get Oncall to post to a [Matrix](https://matrix.org/) room when an alert fires. Since there's no built-in Oncall->Matrix integration as there is with Slack, I've hacked this together by running a Kubernetes service that writes to Matrix when it receives an HTTP request, and having a Oncall webhook call that service. I'd prefer to keep this endpoint visible only within my local network to prevent abuse.

I could just put authentication on my publicly-available webhook endpoint - and, indeed, that's what I'm going to do in the meantime while I try to figure out how to build a "proper" Oncall->Matrix integration (taking inspiration from any progress on the [Mattermost](https://github.com/grafana/oncall/issues/96) integration) - but this feels like unintentional behaviour even if there's a workaround.

# Reproduction of the issue

## Prerequisites

1. An instance of Grafana running _on Kubernetes_, with Oncall plugin installed. The [Helm chart](https://github.com/grafana/oncall/tree/dev/helm/oncall) is helpful here
  * If you're running on Raspberry Pi (as I am), I've detailed the modifications required to the chart [here](https://blog.scubbo.org/posts/grafana-oncall/)
2. Control of your (Kubernetes cluster's) network's local DNS resolver, such that you can configure overrides
3. Control of a publicly-available DNS domain, such that you can resolve a request against a public DNS name to resolve to your Kubernetes cluster's LAN 
  * (If applicable) control of your (Kubernetes cluster's) network's firewall, such that you can forward requests to the Kubernetes cluster 

## Steps to reproduce

1. Install the Helm chart from this repo - `helm install --create-namespace -n <namespace> <name> helm/ --values <values_file>`
  * The only value that _must_ be set is `dnsPublicDomain`
  * Note the Service name, Local name, and Public name output from `NOTES` - they will be used later
2. Add a record to your local DNS resolver, such that the local DNS name in the Helm output will resolve to the Kubernetes cluster's IP
3. Add a record on your publicly-available DNS domain, such that the global DNS name in the Helm output will resolve to the Kubernetes cluster's LAN's IP
  * (If applicable) configure the LAN's firewall such that requests will be redirected to the Kubernetes cluster
4. In one shell window, start tailing logs for the listener: `kubectl logs $(kubectl get pods -o jsonpath='{.items[0].metadata.name}') -c listener -f`
  * All further commands should be carried out in a second local shell window
5. Remotely query the listener from your Oncall Engine's pod: `kubectl -n grafana exec -it $(kubectl -n grafana get pods -l app.kubernetes.io/component=engine --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}') -- wget <service_name_from_helm_output>:8000`
  * Note that your Engine pod's namespace might differ from `grafana` - set as appropriate
  * Confirm that, in the logs window, the request shows up
  * The response in the second (local) shell will be an error, but that doesn't matter - we're just proving connectivity
6. Confirm that your Oncall Engine's Pod can `nslookup` the service name: `kubectl -n grafana exec -it $(kubectl -n grafana get pods -l app.kubernetes.io/component=engine --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}') -- nslookup <service_name_from_helm_output>.svc.cluster.local`
  * Note that the `svc.cluster.local` suffix appears to be required, even though [Kubernetes' resolv.conf should set a search domain of `svc.cluster.local`](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/). I'm not sure why this is happening, but I don't think it's relevant to this issue. In particular, Step 5 succeeds with or without the `svc.cluster.local` suffix
7. Repeat steps 5. and 6. for the local DNS record (as set in Step 2., and as output as "Local name" from Helm output), remembering to check logs to confirm that the request actually hits the listener service
8. Repeat step 7. for the public DNS record (as set in Step 3., and as output as "Public name" from Helm output)
9. In Grafana UI, create an Outgoing Webhook with url `http://<service_name_from_helm_output>:8000`. Create an Escalation Chain which triggers that webhook, and an Integration that uses that Escalation Chain.
  * Note that the `http://` prefix is required - without it, the UI gives an error `Webhook is incorrect`
10. Send a demo alert for the Integration. Note that logs do **not** show a request hitting the listener service.
11. Update the Webhook's url to `http://<local_name_from_helm_output>`. Send a demo alert, and again note **no logs**.
12. Update the Webhook's url to `http://<public_name_from_helm_output>`. Send a demo alert, and note logs **are** generated.

(Remember to undo any firewall configuration or port-forwarding after you're done! :) )

# Assumptions

* Webhook calls are executed from the Engine pod, rather than from another pod within the Oncall deployment. I don't _think_ this would affect the situation (it would be unexpected for two pods in the same deployment to have different name-resolution logic), but I guess it's possible? I did check that the service-based and local-DNS approaches resolve correctly from a Celery pod - I didn't want to go through checking every single Oncall pod since I think that's unlikely to be the cause.

# Setup information

In the interests of complete information - I'm running a [k3s](https://k3s.io/) cluster on 3xRaspberry Pi v4, in a LAN behind an OPNsense 22.1.6-amd64 router.

Grafana version: v9.1.5 (df015a9301)
Oncall plugin version: v1.0.35

# Any other helpful information?

## Logs

Logs from the Engine container when a webhook is triggered:

```
2022-10-01 00:34:02 source=engine:app google_trace_id=none logger=apps.alerts.models.alert_receive_channel send_demo_alert integration=1 force_route_id=1
2022-10-01 00:34:02 source=engine:app google_trace_id=none logger=root inbound latency=0.10254 status=200 method=POST path=/api/internal/v1/channel_filters/R6YNH9IS6KDB8/send_demo_alert content-length=0 slow=0 integration_type=N/A integration_token=N/A
2022-10-01 00:34:02 source=engine:uwsgi status=200 method=POST path=/api/internal/v1/channel_filters/R6YNH9IS6KDB8/send_demo_alert latency=0.108540 google_trace_id=- protocol=HTTP/1.1 resp_size=160 req_body_size=0
```

These are identical (apart from timestamps and latencies) in the succeeding and failing cases.

No logs are generated from the main Grafana container in either case.

## Code search

I did find [this reference](https://github.com/grafana/oncall/blob/dd6975858ae6e8b14c90d4ee2a9b357dcbf93bec/helm/oncall/values.yaml#L107-L110) to public nameservers in the Oncall code - but, given that that's in the context of `cert-manager` (which I have disabled (since my Oncall instance is only accessible from inside my LAN!), and which is nothing to do with webhooks), I doubt that's related.

## Wireshark

I'm an absolute novice with Wireshark, but I've tried to capture some dumps that might prove helpful. They're in this
repo, in the directory titled "wireshark-dumps", with hopefully-self-explanatory names. Some things I noticed:
* When `curl`ing from my laptop to the public name, there's a pattern of 3 packets per call - 2 TLSv1.2, and 1 TCP. This same pattern is present in the successful oncall->receiver invocations (after the HTTP and TCP packets representing the call to `/api/plugin-procy/grafana-oncall-app/api/.../send_demo_alert/`)
* When `curl`ing from my laptop to the local name, that same pattern is present, though there are a lot more packets captured, including the `GET / HTTP/1.1` request and the `HTTP/1.1 501 Not Implemented (text/html)` response
* Those three packets show up when invoking the webhook for the public name, but _not_ when invoking it for the local name.