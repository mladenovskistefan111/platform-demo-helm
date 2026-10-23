# platform-demo-helm

<div class="pd-hero" markdown>
<span class="pd-kicker">deploy · platform-demo</span>

Everything that is deployed: the Helm charts for the platform-demo application (10 services, PostgreSQL, Redis), the Gateway API entry point, and the **GitOps configuration** that makes Argo CD deploy them. This repository is the single source of truth for what runs in each environment; the service repositories only build and publish images.
</div>

<div class="pd-facts" markdown>
<div><span>Deploys with</span><strong>Argo CD</strong><small>ApplicationSets, polled every 2 min</small></div>
<div><span>Environments</span><strong>dev, stage, prod</strong><small>envs/&lt;env&gt;/, one namespace each</small></div>
<div><span>Charts</span><strong>12 workloads</strong><small>+ gateway, Dex, Backstage, policies</small></div>
<div><span>Policies</span><strong>16</strong><small>Kyverno, enforced in the shop namespaces</small></div>
</div>

## Start here

<div class="pd-cards" markdown>
<div><h4><a href="how-it-fits/">How it fits together</a></h4><p>Git, Argo CD, Cilium and Kyverno in one picture.</p></div>
<div><h4><a href="environments/">Environments</a></h4><p>dev, stage and prod on one cluster: namespaces, hosts, secrets, how to add an app or an environment.</p></div>
<div><h4><a href="deploy/">Deploy</a></h4><p>Bootstrap Argo CD on the EKS cluster; GitOps does the rest.</p></div>
<div><h4><a href="policies/">Admission policies</a></h4><p>What Kyverno enforces, how to roll out and test a policy.</p></div>
<div><h4><a href="gitops/">GitOps</a></h4><p>ApplicationSets, projects and how Argo CD manages itself.</p></div>
<div><h4><a href="sso-and-portal/">Single sign-on and the portal</a></h4><p>Dex, Backstage, and how the three UIs share one login.</p></div>
</div>

