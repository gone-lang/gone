import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";
import { checkToolchain, run } from "./toolchain";

const GONE_EXT = ".gone";

let output: vscode.OutputChannel;
let status: vscode.StatusBarItem;

// toolchainState 缓存自检结果, 避免每次打开文件都跑一遍 go build。
let toolchainState: { path: string; ok: boolean; detail: string } | undefined;

export function activate(ctx: vscode.ExtensionContext) {
	output = vscode.window.createOutputChannel("Gone");
	status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
	status.command = "gone.doctor";
	ctx.subscriptions.push(output, status);

	// 语言关联的兜底: 语言贡献(contributes.languages)已经把 .gone 并进 go,
	// 但如果当前 VSCode 没做合并, 这里在打开时手动把语言切成 go,
	// 这样内置的 Go 语法高亮、Go 扩展(gopls 客户端)都能接管。
	const ensure = (doc: vscode.TextDocument) => {
		if (isGoneFile(doc) && doc.languageId !== "go") {
			void vscode.languages.setTextDocumentLanguage(doc, "go");
		}
		refreshStatus();
	};
	ctx.subscriptions.push(vscode.workspace.onDidOpenTextDocument(ensure));
	vscode.workspace.textDocuments.forEach(ensure);

	ctx.subscriptions.push(
		vscode.commands.registerCommand("gone.doctor", () => doctor(true)),
		vscode.commands.registerCommand("gone.setupToolchain", () => setupToolchain()),
	);

	if (vscode.workspace.getConfiguration("gone").get<boolean>("autoConfigure")) {
		void autoConfigure();
	}
}

export function deactivate() {}

function isGoneFile(doc: vscode.TextDocument): boolean {
	return doc.uri.scheme === "file" && doc.fileName.endsWith(GONE_EXT);
}

function hasGoneFileOpen(): boolean {
	return vscode.workspace.textDocuments.some(isGoneFile);
}

/** toolchainPath 依次取 gone.toolchainPath、go.goroot、GOROOT。 */
function toolchainPath(): string {
	const gone = vscode.workspace.getConfiguration("gone").get<string>("toolchainPath");
	if (gone) {
		return gone;
	}
	const goroot = vscode.workspace.getConfiguration("go").get<string>("goroot");
	if (goroot) {
		return goroot;
	}
	return process.env.GOROOT ?? "";
}

function goplsPath(toolchain: string): string {
	const alt = vscode.workspace.getConfiguration("go").get<Record<string, string>>("alternateTools");
	const configured = alt?.["gopls"];
	if (configured) {
		return configured;
	}
	return toolchain ? path.join(toolchain, "bin", "gopls") : "";
}

async function ensureToolchain(): Promise<{ path: string; ok: boolean; detail: string }> {
	const tc = toolchainPath();
	if (!tc) {
		return { path: "", ok: false, detail: "没有配置工具链目录(gone.toolchainPath / go.goroot / GOROOT 都是空的)" };
	}
	// 相对路径按工作区(第一个文件夹)解析, 而不是按扩展自身所在目录
	const cwd = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
	const resolved = path.isAbsolute(tc) || !cwd ? tc : path.resolve(cwd, tc);
	if (!toolchainState || toolchainState.path !== resolved) {
		const { ok, detail } = await checkToolchain(resolved);
		toolchainState = { path: resolved, ok, detail };
	}
	return toolchainState;
}

async function refreshStatus() {
	if (!hasGoneFileOpen()) {
		status.hide();
		return;
	}
	const st = await ensureToolchain();
	status.text = st.ok ? "$(check) Gone" : "$(warning) Gone";
	status.tooltip = st.ok
		? `gone 工具链: ${st.path}\n${st.detail}\n点一下做环境自检`
		: `Gone: 工具链不可用\n${st.detail}\n点一下做环境自检`;
	status.show();
}

async function autoConfigure() {
	if (!hasGoneFileOpen()) {
		return; // 没有 .gone 文件时不动用户的设置
	}
	const tc = vscode.workspace.getConfiguration("gone").get<string>("toolchainPath");
	if (!tc) {
		output.appendLine("提示: 没设置 gone.toolchainPath, 跳过自动配置(可以跑 Gone: 配置 gone 工具链)。");
		return;
	}
	await writeGoSettings(tc, false);
}

/** writeGoSettings 把 go.goroot 与 go.alternateTools.gopls 写到工作区设置。 */
async function writeGoSettings(toolchain: string, verbose: boolean): Promise<boolean> {
	const goConfig = vscode.workspace.getConfiguration("go");
	const target = vscode.ConfigurationTarget.Workspace;
	let changed = false;

	if (goConfig.get<string>("goroot") !== toolchain) {
		await goConfig.update("goroot", toolchain, target);
		output.appendLine(`已设置 go.goroot = ${toolchain}`);
		changed = true;
	} else if (verbose) {
		output.appendLine(`go.goroot 已经是 ${toolchain}`);
	}

	// 用 build-gopls.sh 构建过的 gopls 才有 .gone 支持; 没有就明确说出来。
	const bin = path.join(toolchain, "bin", "gopls");
	const alt = { ...(goConfig.get<Record<string, string>>("alternateTools") ?? {}) };
	if (fs.existsSync(bin)) {
		if (alt["gopls"] !== bin) {
			alt["gopls"] = bin;
			await goConfig.update("alternateTools", alt, target);
			output.appendLine(`已设置 go.alternateTools.gopls = ${bin}`);
			changed = true;
		} else if (verbose) {
			output.appendLine(`go.alternateTools.gopls 已经是 ${bin}`);
		}
	} else {
		output.appendLine(`注意: ${bin} 不存在, gopls 还是官方那份(不认 .gone)。`);
		output.appendLine("      跑 scripts/build-gopls.sh --toolchain <工具链目录> 构建一份。");
	}
	return changed;
}

async function setupToolchain() {
	output.show(true);
	const current = toolchainPath();
	const picked = await vscode.window.showInputBox({
		title: "Gone: gone 工具链目录",
		prompt: "build-toolchain.sh 的产物目录(含 bin/go、bin/gofmt)",
		value: current,
		ignoreFocusOut: true,
	});
	if (picked === undefined) {
		return;
	}
	const toolchain = picked.trim();
	if (!toolchain) {
		await vscode.workspace.getConfiguration("gone").update("toolchainPath", "", vscode.ConfigurationTarget.Workspace);
		output.appendLine("已清空 gone.toolchainPath");
		return;
	}
	if (!fs.existsSync(path.join(toolchain, "bin", "go"))) {
		void vscode.window.showErrorMessage(`Gone: ${toolchain} 里没有 bin/go`);
		return;
	}
	await vscode.workspace.getConfiguration("gone").update("toolchainPath", toolchain, vscode.ConfigurationTarget.Workspace);
	const { ok, detail } = await ensureToolchain();
	if (!ok) {
		void vscode.window.showErrorMessage(`Gone: 这份工具链不认 .gone —— ${detail}`);
		return;
	}
	await writeGoSettings(toolchain, true);
	toolchainState = undefined; // 让状态栏重新自检
	await refreshStatus();
	void vscode.window.showInformationMessage("Gone: 工具链已配置好, 重新加载窗口后生效(命令面板: Developer: Reload Window)。");
}

async function doctor(verbose: boolean) {
	output.show(true);
	const tc = toolchainPath();
	if (!tc) {
		output.appendLine("工具链: 未配置 (设置 gone.toolchainPath, 或设 go.goroot)");
		if (verbose) {
			void vscode.window.showWarningMessage("Gone: 还没配置工具链, 跑一下 “Gone: 配置 gone 工具链”。");
		}
		return;
	}
	const st = await ensureToolchain();
	output.appendLine(`工具链: ${st.path}`);
	output.appendLine(`  ${st.ok ? "OK" : "不可用"} — ${st.detail}`);

	const bin = goplsPath(tc);
	if (bin && fs.existsSync(bin)) {
		const v = await run(bin, ["version"], tc, { ...process.env });
		output.appendLine(`gopls: ${bin}`);
		output.appendLine(`  ${v.out.split("\n")[0]}`);
		const expected = path.join(tc, "bin", "gopls");
		output.appendLine(
			path.resolve(bin) === path.resolve(expected)
				? "  是 build-gopls.sh 装到工具链里的那份(带 .gone 支持)"
				: `  注意: 不是 ${expected}; 请确认这份 gopls 是 build-gopls.sh 的产物`,
		);
	} else {
		output.appendLine(`gopls: 找不到 (${bin || "未配置"})`);
		output.appendLine("  跑 scripts/build-gopls.sh --toolchain " + tc + " 构建一份, 再回来自检。");
	}

	if (verbose) {
		const msg = st.ok
			? "Gone: 工具链 OK, 明细见 Output → Gone"
			: `Gone: 工具链不可用 —— ${st.detail}`;
		void (st.ok ? vscode.window.showInformationMessage(msg) : vscode.window.showErrorMessage(msg));
	}
	await refreshStatus();
}
