// microdeploy - Deploy changes: merge to main branch, push, and update a remote.
//
// Port of microdeploy.sh to Go (single file, stdlib only).
// Process:
//
//  1. git checkout <main_branch>            (main or master)
//  2. git merge <current branch>
//  3. git tag <tag> (optional, on the main branch)
//  4. git checkout <current branch>
//  5. git push <git_remote> <main_branch> dev
//  6. git push <git_remote> <tag> (if --tag was given)
//  7. On the remote (SSH): git pull + ./service.sh restart (solo con --restart-systemd)
package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

// ANSI colors.
const (
	clrRed    = "\033[0;31m"
	clrGreen  = "\033[0;32m"
	clrYellow = "\033[1;33m"
	clrBlue   = "\033[0;34m"
	clrCyan   = "\033[0;36m"
	clrReset  = "\033[0m"
)

func logInfo(format string, a ...interface{}) {
	fmt.Printf("%s[INFO]%s %s\n", clrBlue, clrReset, fmt.Sprintf(format, a...))
}
func logOk(format string, a ...interface{}) {
	fmt.Printf("%s[OK]%s %s\n", clrGreen, clrReset, fmt.Sprintf(format, a...))
}
func logWarn(format string, a ...interface{}) {
	fmt.Printf("%s[WARN]%s %s\n", clrYellow, clrReset, fmt.Sprintf(format, a...))
}
func logErr(format string, a ...interface{}) {
	fmt.Printf("%s[ERR]%s %s\n", clrRed, clrReset, fmt.Sprintf(format, a...))
}
func logStep(format string, a ...interface{}) {
	fmt.Printf("%s[STEP]%s %s\n", clrCyan, clrReset, fmt.Sprintf(format, a...))
}

// Remote is a configured deployment target.
type Remote struct {
	Name       string
	Host       string
	LocalDir   string
	RemoteDir  string
	Branch     string
	MainBranch string
	GitRemote  string
}

func (r Remote) String() string {
	return strings.Join(
		[]string{r.Name, r.Host, r.LocalDir, r.RemoteDir, r.Branch, r.MainBranch, r.GitRemote},
		"|",
	)
}

func homeDir() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	return os.Getenv("USER")
}

// scriptDir returns the directory where the microdeploy binary lives.
func scriptDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

var configFile = filepath.Join(".microdeploy", "remotes.conf") // resolved under homeDir()

// ensureConfigDir creates ~/.microdeploy and migrates a legacy remotes.conf.
func ensureConfigDir(home string) error {
	conf := filepath.Join(home, configFile)
	dir := filepath.Dir(conf)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(conf); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	// Migrate from the binary's directory if present.
	legacy := filepath.Join(scriptDir(), "remotes.conf")
	if _, err := os.Stat(legacy); err != nil {
		return nil
	}
	if err := copyFile(conf, legacy); err != nil {
		return err
	}
	logWarn("Configuración migrada de '%s' a '%s'", legacy, conf)
	return nil
}

func copyFile(dst, src string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func fullConfigPath() string {
	return filepath.Join(homeDir(), configFile)
}

func loadRemotes() ([]Remote, error) {
	home := homeDir()
	if err := ensureConfigDir(home); err != nil {
		return nil, err
	}
	conf := filepath.Join(home, configFile)
	remotes := []Remote{}
	content, err := os.ReadFile(conf)
	if err != nil {
		if os.IsNotExist(err) {
			return remotes, nil
		}
		return nil, err
	}
	for _, line := range strings.Split(string(content), "\n") {
		// Skip empty lines and comments.
		if strings.TrimSpace(line) == "" {
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		f := strings.Split(line, "|")
		n := len(f)
		switch {
		case n == 4:
			// Old format: name|user@host|remote_dir|branch
			logWarn("Remoto '%s' en formato antiguo: se usa '%s' como directorio local, 'main' como rama principal y 'github' como remoto git",
				f[0], scriptDir())
			remotes = append(remotes, Remote{
				Name: f[0], Host: f[1], LocalDir: scriptDir(), RemoteDir: f[2],
				Branch: f[3], MainBranch: "main", GitRemote: "github",
			})
		case n >= 5 && n <= 7:
			branch := "main"
			if f[4] != "" {
				branch = f[4]
			}
			mainBranch := "main"
			if n >= 6 && f[5] != "" {
				mainBranch = f[5]
			}
			gitRemote := "github"
			if n >= 7 && f[6] != "" {
				gitRemote = f[6]
			}
			remotes = append(remotes, Remote{
				Name: f[0], Host: f[1], LocalDir: f[2], RemoteDir: f[3],
				Branch: branch, MainBranch: mainBranch, GitRemote: gitRemote,
			})
		default:
			logWarn("Línea ignorada (%d campos): %s", n, line)
		}
	}
	return remotes, nil
}

func saveRemotes(home string, remotes []Remote) error {
	conf := filepath.Join(home, configFile)
	dir := filepath.Dir(conf)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	var b strings.Builder
	for _, r := range remotes {
		b.WriteString(r.String())
		b.WriteString("\n")
	}
	return os.WriteFile(conf, []byte(b.String()), 0o644)
}

// truncateStr shortens a string to max runes, appending "..." if truncated.
func truncateStr(str string, max int) string {
	if utf8.RuneCountInString(str) <= max {
		return str
	}
	r := []rune(str)
	if max <= 3 {
		return "..."
	}
	return string(r[:max-3]) + "..."
}

func cmdList(remotes []Remote) {
	if len(remotes) == 0 {
		logWarn("No hay remotos configurados. Usa '%s --add' para agregar uno.", os.Args[0])
		return
	}
	fmt.Printf("%sRemotos configurados:%s\n", clrCyan, clrReset)
	fmt.Printf("%-14s %-26s %-30s %-30s %-13s %-13s %-10s\n",
		"NOMBRE", "USUARIO@HOST", "DIR. LOCAL", "DIR. REMOTO", "RAMA", "RAMA PRINC.", "REMOTO GIT")
	fmt.Printf("%-14s %-26s %-30s %-30s %-13s %-13s %-10s\n",
		strings.Repeat("─", 14), strings.Repeat("─", 26), strings.Repeat("─", 30),
		strings.Repeat("─", 30), strings.Repeat("─", 13), strings.Repeat("─", 13),
		strings.Repeat("─", 10))
	for _, r := range remotes {
		// El nombre se muestra siempre completo; el resto se recorta si es largo.
		fmt.Printf("%-14s %-26s %-30s %-30s %-13s %-13s %-10s\n",
			r.Name, truncateStr(r.Host, 26), truncateStr(r.LocalDir, 30),
			truncateStr(r.RemoteDir, 30), truncateStr(r.Branch, 13), truncateStr(r.MainBranch, 13),
			truncateStr(r.GitRemote, 10))
	}
}

func cmdInspect(remotes []Remote, target string) int {
	if target == "" {
		logErr("Debes especificar el nombre del remoto (ej. %s --inspect produccion)", os.Args[0])
		return 1
	}
	for _, r := range remotes {
		if r.Name == target {
			fmt.Printf("%sDetalles del remoto:%s %s\n", clrCyan, clrReset, r.Name)
			fmt.Printf("  Nombre remoto:        %s\n", r.Name)
			fmt.Printf("  Usuario@Host:         %s\n", r.Host)
			fmt.Printf("  Directorio local:     %s\n", r.LocalDir)
			fmt.Printf("  Directorio remoto:    %s\n", r.RemoteDir)
			fmt.Printf("  Rama:                  %s\n", r.Branch)
			fmt.Printf("  Rama principal:        %s\n", r.MainBranch)
			fmt.Printf("  Remoto git:           %s\n", r.GitRemote)
			return 0
		}
	}
	logErr("No se encontró remoto '%s'", target)
	return 1
}

func shortSHA(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

func pluralCnt(n int, singular string) string {
	if n == 1 {
		return fmt.Sprintf("1 %s", singular)
	}
	return fmt.Sprintf("%d %ss", n, singular)
}

func countCommits(dir, rangeSpec string) (int, error) {
	out, err := runOutput(dir, "git", "rev-list", "--count", rangeSpec)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(out)
}

// cmdStatus muestra cuántos commits de diferencia hay entre el repo local
// (rama actual) y el repo del servidor remoto (rama configurada), indicando
// si el remoto está actualizado, atrasado o adelantado.
func cmdStatus(remotes []Remote, target string) int {
	if len(remotes) == 0 {
		logWarn("No hay remotos configurados. Usa '%s --add' para agregar uno.", os.Args[0])
		return 1
	}
	if target != "" && !findRemote(remotes, target) {
		logErr("No se encontró remoto '%s'", target)
		return 1
	}

	failed := 0
	success := 0

	for _, r := range remotes {
		if target != "" && r.Name != target {
			continue
		}

		fmt.Printf("%s[STATUS]%s %s (%s:%s)\n", clrCyan, clrReset, r.Name, r.Host, r.RemoteDir)

		// 1. Validar que el directorio local exista y sea un repositorio git.
		if fi, err := os.Stat(r.LocalDir); err != nil || !fi.IsDir() {
			logErr("El directorio local '%s' no existe", r.LocalDir)
			failed++
			fmt.Println()
			continue
		}
		if err := runSilent(r.LocalDir, "git", "rev-parse", "--is-inside-work-tree"); err != nil {
			logErr("'%s' no es un repositorio git", r.LocalDir)
			failed++
			fmt.Println()
			continue
		}

		// 2. Rama actual y HEAD del repo local.
		localBranch, err := runOutput(r.LocalDir, "git", "rev-parse", "--abbrev-ref", "HEAD")
		if err != nil {
			logErr("No se pudo determinar la rama actual en %s", r.LocalDir)
			failed++
			fmt.Println()
			continue
		}
		localSHA, err := runOutput(r.LocalDir, "git", "rev-parse", "HEAD")
		if err != nil {
			logErr("No se pudo determinar el HEAD local en %s", r.LocalDir)
			failed++
			fmt.Println()
			continue
		}

		// 3. Traer solo el puntero de la rama configurada del repo del servidor
		//    (se escribe únicamente en FETCH_HEAD, sin tocar refs ni working tree).
		sshURL := r.Host + ":" + r.RemoteDir
		if out, err := runOutput(r.LocalDir, "git", "-c",
			"core.sshCommand=ssh -o ConnectTimeout=10 -o BatchMode=yes",
			"fetch", sshURL, "refs/heads/"+r.Branch); err != nil {
			logErr("No se pudo contactar el repo remoto (%s): %s", sshURL, out)
			failed++
			fmt.Println()
			continue
		}
		remoteSHA, err := runOutput(r.LocalDir, "git", "rev-parse", "FETCH_HEAD")
		if err != nil {
			logErr("No se pudo leer FETCH_HEAD en %s", r.LocalDir)
			failed++
			fmt.Println()
			continue
		}

		// 4. Contar la diferencia en ambas direcciones.
		localAhead, err := countCommits(r.LocalDir, "FETCH_HEAD..HEAD")
		if err != nil {
			logErr("No se pudieron contar los commits (local adelantado)")
			failed++
			fmt.Println()
			continue
		}
		remoteAhead, err := countCommits(r.LocalDir, "HEAD..FETCH_HEAD")
		if err != nil {
			logErr("No se pudieron contar los commits (remoto adelantado)")
			failed++
			fmt.Println()
			continue
		}

		// 5. Resultado.
		fmt.Printf("  local  (%-10s): %s\n", localBranch, shortSHA(localSHA))
		fmt.Printf("  remoto (%-10s): %s\n", r.Branch, shortSHA(remoteSHA))
		switch {
		case localAhead == 0 && remoteAhead == 0:
			logOk("Remoto '%s' está actualizado (al día)", r.Name)
		case localAhead > 0 && remoteAhead == 0:
			logWarn("El remoto '%s' está %s ATRASADO (despliegue pendiente)", r.Name, pluralCnt(localAhead, "commit"))
		case localAhead == 0 && remoteAhead > 0:
			logWarn("El remoto '%s' está %s ADELANTADO (local atrasado)", r.Name, pluralCnt(remoteAhead, "commit"))
		default:
			logWarn("Local y remoto '%s' divergieron: local +%d, remoto +%d", r.Name, localAhead, remoteAhead)
		}
		success++
		fmt.Println()
	}

	if target == "" && len(remotes) > 1 {
		fmt.Printf("%sResumen:%s %d exitoso(s), %d fallido(s)\n", clrCyan, clrReset, success, failed)
	}
	if failed > 0 {
		return 1
	}
	return 0
}

func findRemote(remotes []Remote, name string) bool {
	for _, r := range remotes {
		if r.Name == name {
			return true
		}
	}
	return false
}

func prompt(reader *bufio.Reader, label, def string) string {
	fmt.Printf("%s: ", label)
	text, _ := reader.ReadString('\n')
	text = strings.TrimSpace(text)
	if text == "" {
		return def
	}
	return text
}

func cmdAdd() int {
	home := homeDir()
	remotes, err := loadRemotes()
	if err != nil {
		logErr("%v", err)
		return 1
	}
	fmt.Printf("%sAgregar nuevo remoto%s\n", clrCyan, clrReset)
	reader := bufio.NewReader(os.Stdin)
	name := prompt(reader, "Nombre (ej. produccion)", "")
	if name == "" {
		logErr("El nombre es obligatorio")
		return 1
	}
	host := prompt(reader, "Usuario@Host (ej. ubuntu@192.168.1.100)", "")
	if host == "" {
		logErr("El host es obligatorio")
		return 1
	}
	localDir := prompt(reader, "Directorio local del proyecto (ej. /home/jose/mi-proyecto)", "")
	if localDir == "" {
		logErr("El directorio local es obligatorio")
		return 1
	}
	remoteDir := prompt(reader, "Directorio remoto (ej. /home/ubuntu/mi-proyecto)", "")
	if remoteDir == "" {
		logErr("El directorio remoto es obligatorio")
		return 1
	}
	branch := prompt(reader, "Rama a desplegar en el remoto (default: main)", "main")
	mainBranch := prompt(reader, "Rama principal local, main/master (default: main)", "main")
	gitRemote := prompt(reader, "Remoto git para push (default: github)", "github")

	if findRemote(remotes, name) {
		logErr("Ya existe un remoto con nombre '%s'", name)
		return 1
	}

	if fi, err := os.Stat(localDir); err != nil || !fi.IsDir() {
		logWarn("El directorio local '%s' no existe en este equipo", localDir)
	}

	remotes = append(remotes, Remote{
		Name: name, Host: host, LocalDir: localDir, RemoteDir: remoteDir,
		Branch: branch, MainBranch: mainBranch, GitRemote: gitRemote,
	})
	if err := saveRemotes(home, remotes); err != nil {
		logErr("%v", err)
		return 1
	}
	logOk("Remoto '%s' agregado", name)
	return 0
}

func cmdRemove(target string) int {
	if target == "" {
		logErr("Debes especificar el nombre del remoto a eliminar")
		return 1
	}
	home := homeDir()
	remotes, err := loadRemotes()
	if err != nil {
		logErr("%v", err)
		return 1
	}
	newRemotes := []Remote{}
	found := false
	for _, r := range remotes {
		if r.Name == target {
			found = true
		} else {
			newRemotes = append(newRemotes, r)
		}
	}
	if !found {
		logErr("No se encontró remoto '%s'", target)
		return 1
	}
	if err := saveRemotes(home, newRemotes); err != nil {
		logErr("%v", err)
		return 1
	}
	logOk("Remoto '%s' eliminado", target)
	return 0
}

// runCmd runs a command in dir, streaming output to the terminal.
func runCmd(dir string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// runSilent runs a command discarding stdout/stderr, returning only success.
func runSilent(dir string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}

// runOutput runs a command in dir and returns its combined output (trimmed).
func runOutput(dir string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

// deployLocal runs the local steps. Returns an error on failure.
func deployLocal(localDir, mainBranch, tag, gitRemote string) error {
	if mainBranch == "" {
		mainBranch = "main"
	}
	if localDir == "" {
		logErr("Falta el directorio local del proyecto en la configuración")
		return errors.New("missing local dir")
	}
	if fi, err := os.Stat(localDir); err != nil || !fi.IsDir() {
		logErr("El directorio local '%s' no existe", localDir)
		return errors.New("local dir does not exist")
	}
	if err := runSilent(localDir, "git", "rev-parse", "--is-inside-work-tree"); err != nil {
		logErr("'%s' no es un repositorio git", localDir)
		return err
	}

	// Check that main branch exists.
	if err := runSilent(localDir, "git", "show-ref", "--verify", "--quiet", "refs/heads/"+mainBranch); err != nil {
		logErr("No existe la rama '%s' en %s", mainBranch, localDir)
		return err
	}

	currentBranch, err := runOutput(localDir, "git", "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		logErr("No se pudo determinar la rama actual en %s", localDir)
		return err
	}
	if currentBranch == "" || currentBranch == "HEAD" {
		logErr("No se pudo determinar la rama actual")
		return errors.New("cannot determine current branch")
	}

	logInfo("Rama actual (CURRENT_BRANCH): %s", currentBranch)
	logInfo("Rama principal: %s", mainBranch)

	// Validate the tag before touching branches.
	if tag != "" {
		if err := runSilent(localDir, "git", "rev-parse", "--verify", "refs/tags/"+tag); err == nil {
			logErr("El tag '%s' ya existe", tag)
			return errors.New("tag already exists")
		}
	}

	logStep("git checkout %s", mainBranch)
	if err := runCmd(localDir, "git", "checkout", mainBranch); err != nil {
		return err
	}

	logStep("git merge --no-edit %s", currentBranch)
	if err := runCmd(localDir, "git", "merge", "--no-edit", currentBranch); err != nil {
		return err
	}

	if tag != "" {
		logStep("git tag %s", tag)
		if err := runCmd(localDir, "git", "tag", tag); err != nil {
			return err
		}
	}

	logStep("git checkout %s", currentBranch)
	if err := runCmd(localDir, "git", "checkout", currentBranch); err != nil {
		return err
	}

	logStep("git push %s %s dev", gitRemote, mainBranch)
	if err := runCmd(localDir, "git", "push", gitRemote, mainBranch, "dev"); err != nil {
		return err
	}

	if tag != "" {
		logStep("git push %s %s", gitRemote, tag)
		if err := runCmd(localDir, "git", "push", gitRemote, tag); err != nil {
			return err
		}
	}

	if tag != "" {
		logOk("Pasos locales completados: %s actualizada, pusheada a %s (tag: %s)", mainBranch, gitRemote, tag)
	} else {
		logOk("Pasos locales completados: %s actualizada y pusheada a %s", mainBranch, gitRemote)
	}
	return nil
}

// updateRemote runs git pull (and optionally ./service.sh restart) on the remote via SSH.
func updateRemote(name, host, remoteDir, branch string, restartSystemd bool) error {
	logStep("Actualizando %s (%s:%s)...", name, host, remoteDir)

	// Check SSH connectivity.
	if err := runSilent("", "ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host, "true"); err != nil {
		logErr("No se puede conectar a %s via SSH", host)
		return err
	}

	restartStep := ""
	restartEcho := "echo 'Servicio no reiniciado (usa --restart-systemd para reiniciarlo)'"
	if restartSystemd {
		restartStep = "./service.sh restart 2>&1"
		restartEcho = "echo 'Servicio reiniciado'"
	}

	remoteCmd := fmt.Sprintf(`
        set -euo pipefail
        cd '%s' || { echo 'Directorio no existe'; exit 1; }
        echo 'Directorio actual: ' $PWD
        git pull origin '%s' 2>&1
        echo 'Git pull completado'
        %s
        %s
`, remoteDir, branch, restartStep, restartEcho)

	if err := runCmd("", "ssh", host, remoteCmd); err != nil {
		logErr("Error actualizando %s", name)
		return err
	}
	logOk("%s actualizado correctamente", name)
	return nil
}

// parseDeployArgs parses --tag <tag>, --restart-systemd, and an optional target name.
func parseDeployArgs(args []string) (tag, target string, restartSystemd bool, err error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--tag" || a == "-t":
			if i+1 >= len(args) || args[i+1] == "" {
				return "", "", false, errors.New("El parámetro --tag requiere un nombre de tag (ej. v1.2.3)")
			}
			tag = args[i+1]
			i++
		case a == "--restart-systemd":
			restartSystemd = true
		case strings.HasPrefix(a, "-"):
			return "", "", false, fmt.Errorf("Argumento desconocido: %s", a)
		default:
			if target != "" {
				return "", "", false, fmt.Errorf("Argumento inesperado: %s", a)
			}
			target = a
		}
	}
	return tag, target, restartSystemd, nil
}

func cmdDeploy(tag, target string, restartSystemd bool) int {
	if _, err := exec.LookPath("git"); err != nil {
		logErr("git no está disponible en este sistema")
		return 1
	}
	if target == "" {
		logErr("Debes especificar el remoto a actualizar (ej. %s produccion).", os.Args[0])
		return 1
	}

	remotes, err := loadRemotes()
	if err != nil {
		logErr("%v", err)
		return 1
	}
	if len(remotes) == 0 {
		logWarn("No hay remotos configurados. Usa '%s --add' para agregar uno.", os.Args[0])
		return 1
	}
	if !findRemote(remotes, target) {
		logErr("No se encontró remoto '%s'", target)
		return 1
	}

	failed := 0
	success := 0
	processed := map[string]bool{}

	for _, r := range remotes {
		if r.Name != target {
			continue
		}
		key := r.LocalDir + "|" + r.MainBranch
		if !processed[key] {
			if err := deployLocal(r.LocalDir, r.MainBranch, tag, r.GitRemote); err != nil {
				return 1
			}
			processed[key] = true
		}
		if err := updateRemote(r.Name, r.Host, r.RemoteDir, r.Branch, restartSystemd); err != nil {
			failed++
		} else {
			success++
		}
		fmt.Println()
	}

	fmt.Printf("%sResumen:%s %d exitoso(s), %d fallido(s)\n", clrCyan, clrReset, success, failed)
	if failed > 0 {
		return 1
	}
	return 0
}

func showHelp() {
	prog := os.Args[0]
	fmt.Printf(`%[3]sdeploy.sh%[1]s - Desplegar cambios: merge a la rama principal, push y actualizar un remoto

%[2]sProceso:%[1]s
  1. git checkout <rama principal> (main/master, configurable)
  2. git merge <rama actual>
  3. git tag <tag> (opcional, sobre la rama principal)
  4. git checkout <rama actual>
  5. git push <remoto_git> <rama principal> dev
  6. git push <remoto_git> <tag> (si se indicó --tag)
  7. En el remoto (SSH): git pull + ./service.sh restart (solo con --restart-systemd)

%[2]sUso:%[1]s
  %[4]s                    Lista los remotos configurados
  %[4]s <nombre>           Despliega y actualiza solo el remoto especificado
  %[4]s --tag <tag> <nombre>  Despliega el remoto y además crea y pushea un tag al remoto git
  %[4]s <nombre> --restart-systemd  Despliega y además ejecuta ./service.sh restart en el remoto
  %[4]s --list             Lista los remotos configurados
  %[4]s --add              Agrega un remoto interactivamente
  %[4]s --remove <nombre>  Elimina un remoto
  %[4]s --inspect <nombre> Muestra detalles completos del remoto
  %[4]s --status           Compara commits local vs remoto de todos los remotos
  %[4]s --status <nombre>  Compara commits local vs remoto de un remoto específico
  %[4]s --help             Muestra esta ayuda

%[2]sNota:%[1]s el despliegue siempre requiere indicar el remoto a actualizar.
No existe opción para actualizar todos los remotos a la vez.

%[2]sArchivo de configuración:%[1]s %[5]s
Formato: nombre|user@host|directorio_local|directorio_remoto|rama|main_branch|remoto_git

%[2]sEjemplo remotes.conf:%[1]s
  produccion|ubuntu@192.168.1.100|/home/jose/proyectos/baileys-bridge|/home/ubuntu/baileys-bridge|main|main|github
  staging|deploy@staging.empresa.com|/home/jose/proyectos/baileys-bridge|/opt/baileys-bridge|develop|main|github

%[2]sRequisitos:%[1]s
  - Acceso SSH sin contraseña (claves SSH) a los servidores remotos
  - El directorio remoto debe ser un repositorio git con remote 'origin'
  - El usuario SSH debe tener permisos de escritura en el directorio
  - ./service.sh restart (con --restart-systemd) requiere permisos de root en el servidor (sudo)

%[2]sEjemplos:%[1]s
  %[4]s                               # Lista los remotos configurados
  %[4]s produccion                    # Despliega y actualiza solo 'produccion' (sin reiniciar servicio)
  %[4]s produccion --restart-systemd  # Despliega y ejecuta ./service.sh restart en el remoto
  %[4]s --tag v1.2.3 produccion --restart-systemd  # Tag + despliegue + reinicio del servicio
  %[4]s --add                         # Agrega nuevo remoto
  %[4]s --remove staging              # Elimina 'staging'
`, clrReset, clrBlue, clrCyan, prog, fullConfigPath())
}

func main() {
	args := os.Args[1:]

	if len(args) == 0 {
		remotes, err := loadRemotes()
		if err != nil {
			logErr("%v", err)
			os.Exit(1)
		}
		cmdList(remotes)
		os.Exit(0)
	}

	switch args[0] {
	case "--list", "-l":
		remotes, err := loadRemotes()
		if err != nil {
			logErr("%v", err)
			os.Exit(1)
		}
		cmdList(remotes)
	case "--add", "-a":
		os.Exit(cmdAdd())
	case "--remove", "-r":
		target := ""
		if len(args) > 1 {
			target = args[1]
		}
		os.Exit(cmdRemove(target))
	case "--inspect", "-i":
		target := ""
		if len(args) > 1 {
			target = args[1]
		}
		remotes, err := loadRemotes()
		if err != nil {
			logErr("%v", err)
			os.Exit(1)
		}
		os.Exit(cmdInspect(remotes, target))
	case "--status", "-s":
		target := ""
		if len(args) > 1 {
			target = args[1]
		}
		remotes, err := loadRemotes()
		if err != nil {
			logErr("%v", err)
			os.Exit(1)
		}
		os.Exit(cmdStatus(remotes, target))
	case "--help", "-h":
		showHelp()
	default:
		tag, target, restartSystemd, err := parseDeployArgs(args)
		if err != nil {
			logErr("%v", err)
			os.Exit(1)
		}
		os.Exit(cmdDeploy(tag, target, restartSystemd))
	}
}
