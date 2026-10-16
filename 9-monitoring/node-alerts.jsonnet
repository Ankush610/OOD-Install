// node_exporter's own alert set (node-mixin), pinned to NODE_EXPORTER_VERSION, with our overrides.
// node-alerts.yml is rendered from this ONCE, by hand, and kept in git: the install needs no jsonnet.
// Re-render after changing this file or NODE_EXPORTER_VERSION (go-jsonnet binary, github.com/google/go-jsonnet):
//   curl -fsSL https://github.com/prometheus/node_exporter/archive/refs/tags/v<ver>.tar.gz | tar xz
//   jsonnet -J node_exporter-<ver>/docs/node-mixin node-alerts.jsonnet |
//     python3 -c 'import json,sys,yaml; yaml.add_representer(str, lambda d, s: d.represent_scalar("tag:yaml.org,2002:str", s, style="|" if "\n" in s else None)); print(yaml.dump(json.load(sys.stdin), sort_keys=False, width=200))' >> node-alerts.yml
//   (keep node-alerts.yml's comment header; promtool check rules node-alerts.yml)
local mixin = (import 'config.libsonnet') + (import 'alerts/alerts.libsonnet') + {
  _config+:: {
    // local disks only: every NFS client would repeat master's /home alert; tmpfs/vfat/fuse are noise
    fsSelector: 'fstype=~"ext4|xfs|btrfs"',
  },
};
local drop = [
  'NodeCPUHighUsage',          // compute nodes at 100% CPU is the point of HPC
  'NodeSystemSaturation',      // same
  'NodeSystemdServiceFailed',  // our ServiceDown (rules.yml) covers failed AND stopped
];
// summary = the description, naming our `node` instead of the scrape address: the Cluster monitor shows summaries
local named(r) = r + { annotations: { summary: std.strReplace(r.annotations.description, '$labels.instance', '$labels.node') } };
{
  groups: [
    g { rules: [named(r) for r in g.rules if !std.member(drop, r.alert)] }
    for g in mixin.prometheusAlerts.groups
  ],
}
