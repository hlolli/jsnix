package main

import "fmt"
// import "io"
import "io/ioutil"
// import "io/fs"
import "log"
import "os"
import "os/exec"
import "path"
import "reflect"
import "regexp"
import "strings"
// import "syscall"
import "github.com/valyala/fastjson"

var shebangRegex,_ = regexp.Compile(`^#!(.*)`)
var nodejsPath = Which("node")

func InstallBin(outDir string, binPath string) {
    if PathExists(binPath) {
        read, err := ioutil.ReadFile(binPath)
        if err != nil {
            log.Fatal(err)
        }
        ioutil.WriteFile(binPath, []byte(shebangRegex.ReplaceAllString(string(read), nodejsPath)), 0)

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
    pkgName := v.Get("name")
    maybeBin := v.Get("bin")

    if maybeBin != nil {
        if maybeBin.Type().String() == "string" {
            InstallBin(path.Join(outDir, pkgName.String()), path.Join(pkgPath, string(v.GetStringBytes("bin"))))
        } else if (maybeBin.Type().String() == "object") {
            v.GetObject("bin").Visit(func(k []byte, v *fastjson.Value) {
                if (v.Type().String() == "string") {
                    InstallBin(path.Join(outDir, string(k)), path.Join(pkgPath, string(v.GetStringBytes())))
                }
            })
        }
    }

    // Visit will call the callback for each item in v.foods.
    // v.GetObject("foods").Visit(func(foodName []byte, foodValue *fastjson.Value) {
    //     fmt.Printf("%s = %s\n", foodName, foodValue)
    // })
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

func main() {
    outDir := os.Getenv("out")
    if len(os.Args) >= 2 {
        outDir = os.Args[1]
    }

    outBinDir := path.Join(outDir, "bin")

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
                topLevelDeps = append(topLevelDeps, path.Join(scopedDir, topFile.Name()))
            }
		}
		for _, pkg := range topLevelDeps {
		    maybePkg := path.Join(pkg, "package.json")
		    if PathExists(maybePkg) {
                ResolveBins(outDir, pkg, maybePkg)
		    }
		}

	} else {
		fmt.Println("no node_modules found for flattening", PathExists(outBinDir))
	}
}
