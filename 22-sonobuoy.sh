#!/bin/bash
# See also https://github.com/SovereignCloudStack/standards/issues/982
sonobuoy run --plugin-env=e2e.E2E_PROVIDER=openstack --e2e-skip="\[Disruptive\]|NoExecuteTaintManager|HostPort validates that there is no conflict between pods with same hostPort but different hostIP and protocol"
