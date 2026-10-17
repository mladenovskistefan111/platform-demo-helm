# platform-demo-helm

<div class="pd-hero" markdown>
<span class="pd-kicker">deploy · platform-demo</span>

Everything that is deployed: the Helm charts for the platform-demo application (10 services, PostgreSQL, Redis), the Gateway API entry point, a local monitoring stack, and the **GitOps configuration** that makes Argo CD deploy them. This repository is the single source of truth for what runs in each environment; the service repositories only build and publish images.
</div>

<div class="pd-facts" markdown>
<div><span>Deploys with</span><strong>Argo CD</strong><small>ApplicationSets, polled every 2 min</small></div>
<div><span>Environments</span><strong>dev</strong><small>envs/&lt;env&gt;/ directories</small></div>
<div><span>Charts</span><strong>12 workloads</strong><small>+ gateway, monitoring, policies</small></div>
<div><span>Policies</span><strong>16</strong><small>Kyverno, enforced in platform-demo</small></div>
</div>

## Start here

<div class="pd-cards" markdown>
<div><h4><a href="how-it-fits/">How it fits together</a></h4><p>Git, Argo CD, Cilium and Kyverno in one picture.</p></div>
<div><h4><a href="quick-start/">Quick start</a></h4><p>One command builds the whole local cluster.</p></div>
<div><h4><a href="policies/">Admission policies</a></h4><p>What Kyverno enforces, how to roll out and test a policy.</p></div>
<div><h4><a href="gitops/">GitOps</a></h4><p>ApplicationSets, projects and how Argo CD manages itself.</p></div>
<div><h4><a href="local-cluster/">Local cluster</a></h4><p>The kind bootstrap, step by step.</p></div>
<div><h4><a href="sso-and-portal/">Single sign-on and the portal</a></h4><p>Dex, Backstage, and how the three UIs share one login.</p></div>
</div>

