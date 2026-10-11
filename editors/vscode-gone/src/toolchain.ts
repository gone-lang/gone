// 与 VSCode API 无关的工具链判定逻辑, 这样可以用普通 node 跑测试。
import { execFile } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

export interface ToolchainCheck {
	ok: boolean;
	detail: string;
}

export function run(
	file: string,
	args: string[],
	cwd: string,
	env: NodeJS.ProcessEnv,
): Promise<{ code: number; out: string }> {
	return new Promise((resolve) => {
		execFile(file, args, { cwd, env, timeout: 120_000 }, (err, stdout, stderr) => {
			const code = err && typeof (err as { code?: number }).code === "number" ? (err as { code: number }).code : err ? 1 : 0;
			resolve({ code, out: `${stdout}${stderr}`.trim() });
		});
	});
}

/**
 * 判断一份 GOROOT 是不是 gone 工具链。
 *
 * 版本号、目录名都看不出来, 唯一可靠的办法是在临时 module 里真的编译一个
 * 带 !err 语法糖的 .gone 文件: 官方工具链会报 no Go files / non-name !err。
 */
export async function checkToolchain(toolchain: string, cwd?: string): Promise<ToolchainCheck> {
	if (!path.isAbsolute(toolchain) && cwd) {
		toolchain = path.resolve(cwd, toolchain);
	}
	const goBin = path.join(toolchain, "bin", "go");
	if (!fs.existsSync(goBin)) {
		return { ok: false, detail: `${goBin} 不存在` };
	}
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gone-vscode-"));
	try {
		fs.writeFileSync(path.join(dir, "go.mod"), "module gonecheck\n\ngo 1.27\n");
		fs.writeFileSync(
			path.join(dir, "main.gone"),
			'package main\n\nimport "fmt"\n\nfunc g() (int, error) { return 1, nil }\n\n' +
				"func main() {\n\tx, !err := g()\n\tfmt.Println(x)\n}\n",
		);
		const env = {
			...process.env,
			GOROOT: toolchain,
			PATH: `${path.join(toolchain, "bin")}${path.delimiter}${process.env.PATH ?? ""}`,
		};
		const version = await run(goBin, ["version"], dir, env);
		const build = await run(goBin, ["build", "-o", path.join(dir, "out"), "."], dir, env);
		if (build.code !== 0) {
			return {
				ok: false,
				detail: `${toolchain} 不认 .gone 语法糖 (${version.out})：${build.out.split("\n")[0] || "编译失败"}`,
			};
		}
		return { ok: true, detail: version.out };
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}
