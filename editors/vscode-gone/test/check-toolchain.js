#!/usr/bin/env node
// 工具链判定的冒烟测试: 第一份必须是 gone 工具链(认 .gone 语法糖), 其余必须不是。
//
//   node test/check-toolchain.js <gone-toolchain> [stock-toolchain ...]
//
// 需要先 tsc -p .(build.sh 会做)。
const { checkToolchain } = require("../out/toolchain");

async function main() {
	const args = process.argv.slice(2);
	if (args.length < 1) {
		console.error("用法: node test/check-toolchain.js <gone-toolchain> [stock-toolchain ...]");
		process.exit(2);
	}
	let failed = 0;
	for (const [i, dir] of args.entries()) {
		const want = i === 0;
		const got = await checkToolchain(dir);
		const ok = got.ok === want;
		console.log(`${ok ? "ok  " : "FAIL"} ${dir}: gone=${got.ok} (期望 ${want}) — ${got.detail}`);
		if (!ok) {
			failed++;
		}
	}
	process.exit(failed === 0 ? 0 : 1);
}

main();
