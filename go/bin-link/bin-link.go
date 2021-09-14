package main

import "fmt"
import "io/ioutil"
import "log"
import "os"
import "path"
import "regexp"
import "strings"
import "github.com/valyala/fastjson"
import exec "golang.org/x/sys/execabs"

var shebangRegex,_ = regexp.Compile(`^#!(.*)`)
var nodejsPath = Which("node")

func InstallBin(outDir string, binName string, binPath string) {
	outBinDir := path.Join(outDir, "bin")

	if PathExists(binPath) && !IsDir(binPath) {
		read, err := ioutil.ReadFile(binPath)
		if err != nil {
			log.Fatal(err)
		}
		ioutil.WriteFile(binPath, []byte(shebangRegex.ReplaceAllString(string(read), "#!" + nodejsPath)), 0)
		if !PathExists(outBinDir) {
			os.MkdirAll(outBinDir, 0755)
		}
		os.Symlink(binPath, path.Join(outBinDir, binName))
	}
}

func ResolveBins(outDir string, pkgPath string, pkgJson string) {
	pkgJsonBytes, err := ioutil.ReadFile(pkgJson)

	if err != nil {
		fmt.Print(err)
	}
	var p fastjson.Parser
	v, jerr := p.Parse(string(pkgJsonBytes))
	if jerr != nil {
		log.Fatal(jerr)
	}
	pkgName := string(v.GetStringBytes("name"))
	maybeBin := v.Get("bin")
	pwd, _ := os.Getwd()

	binPathSuffix := path.Join(pkgPath, string(v.GetStringBytes()))

	if maybeBin != nil {
		if maybeBin.Type().String() == "string" {
			InstallBin(outDir, pkgName, path.Join(pwd, path.Join(pkgPath, string(v.GetStringBytes("bin")))))
		} else if (maybeBin.Type().String() == "object") {
			v.GetObject("bin").Visit(func(k []byte, vv *fastjson.Value) {
				if (vv.Type().String() == "string") {
					InstallBin(outDir, string(k), path.Join(path.Join(pwd, binPathSuffix), string(vv.GetStringBytes())))
				}
			})
		}
	}
}

func Which(bin string) string {
	path, err := exec.LookPath(bin)
	if err != nil {
		fmt.Println("Could not find path", bin)
	}
	return path
}

func PathExists(filename string) bool {
	if _, err := os.Stat(filename); os.IsNotExist(err) {
		return false
	} else {
		return true
	}
}

func IsDir(p string) bool {
	fileInfo, err := os.Stat(p)
	if err != nil {
		return false
	} else if fileInfo.IsDir() {
		return true
	} else {
		return false
	}
}


func main() {
	outDir := os.Getenv("out")
	if len(os.Args) >= 2 {
		outDir = os.Args[1]
	}

	if PathExists("node_modules") {
		var topLevelDeps []string
		var topLevelScopedDirs []string
		topLevelDepsInfo, lsErr := ioutil.ReadDir("node_modules")
		if lsErr != nil {
			log.Fatal(lsErr)
		}

		for _, topFile := range topLevelDepsInfo {
			if strings.HasPrefix(topFile.Name(), "@") {
				topLevelScopedDirs = append(topLevelScopedDirs, path.Join("./node_modules", topFile.Name()))
			} else {
				topLevelDeps = append(topLevelDeps, path.Join("./node_modules", topFile.Name()))
			}
		}

		for _, scopedDir := range topLevelScopedDirs {
			scopedPkgs, lsErr := ioutil.ReadDir(scopedDir)
			if lsErr != nil {
				log.Fatal(lsErr)
			}
			for _, topFile := range scopedPkgs {
				scopedPkg :=  path.Join(scopedDir, topFile.Name())
				if IsDir(scopedPkg) {
					topLevelDeps = append(topLevelDeps, scopedPkg)
				}
			}
		}
		for _, pkg := range topLevelDeps {
			if IsDir(pkg) {
				maybePkg := path.Join(pkg, "package.json")
				if PathExists(maybePkg) {
					ResolveBins(outDir, pkg, maybePkg)
				}
			}
		}

	} else {
		fmt.Println("no node_modules for bin-link")
	}
}
