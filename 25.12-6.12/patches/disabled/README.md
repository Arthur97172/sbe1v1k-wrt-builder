# 暂时停用的补丁

本目录不在 `patches/*.patch` 的匹配范围内（prepare-tree.sh 按该通配符应用），
因此这里放着的补丁不会进入任何构建。

## 0027-qualcommbe-sbe1v1k-boot-blockers.patch

2026-11-15 停用，用于 **v28 对照构建**：v26 起不来且现场取证证明它从未到达
用户态（overlay 尾部 ext4 `s_mnt_count = 0`，见
`docs/V26_RECOVERY_DIAG_2026-11-15.md`），而 0027 是相对"到过用户态"的 v24
唯一的代码差异。v28 = v25/v26 代码去掉 0027，用来判定 0027 是否为回归源。

- 停用状态下的期望：DTB 重新带上 CPU `operating-points-v2`、`sleep-clk` 有
  `clock-frequency`、没有 `nss@40000000` 保留区。
  `scripts/ci/prepare-tree.sh`（源码断言）与 `scripts/ci/verify-image.sh`
  （反编译 DTB）会按"补丁是否存在"自动切换断言方向，停用时断言的是上述
  **对照形态**，防止镜像悄悄不是这个实验所要求的样子。
- 恢复：把本文件移回 `../`（`git mv`），断言会自动切回"修复形态"。若 v28
  证明 0027 无辜，也可以用 `git revert` 恢复当初把它移走的提交。
