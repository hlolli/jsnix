package main

import "fmt"
import "io/ioutil"
import "io/fs"
import "log"
import "os"
import "path"
import "regexp"
import "sort"
import "strings"
import "syscall"
import "github.com/otiai10/copy"
import "github.com/blang/semver"
import "github.com/karrick/godirwalk"
import "github.com/valyala/fastjson"

var scopedModuleRe,_ = regexp.Compile(`node_modules/@([^/])*/([^/])*$`)
var stdModuleRe,_ = regexp.Compile(`node_modules/[^@^/]*$`)
var fwdSlash = regexp.MustCompile("/")

// 1 = pkgjson1 is greater than pkgjson2
// -1 = pkgjson2 is greater than pkgjson1
func semverCompare(pkgJson1 string, pkgJson2 string) int {

	pkgJsonBytes1, err1 := ioutil.ReadFile(pkgJson1)

	if err1 != nil {
		return 0
	}

	pkgJsonBytes2, err2 := ioutil.ReadFile(pkgJson2)

	if err2 != nil {
		return 0
	}

	type PackageJson struct {
		version string
	}
	var p1 fastjson.Parser

	pv1, jerr1 := p1.Parse(string(pkgJsonBytes1))
	if jerr1 != nil {
		return 0
	}
	ver1 := string(pv1.GetStringBytes("version"))

	var p2 fastjson.Parser

	pv2, jerr2 := p2.Parse(string(pkgJsonBytes2))
	if jerr2 != nil {
		return 0
	}
	ver2 := string(pv2.GetStringBytes("version"))

	v1, err1 := semver.Make(ver1)
	v2, err2 := semver.Make(ver2)
	res := v1.Compare(v2)
	// fmt.Println(pkgJson1 + " " + ver1, pkgJson2 + " " + ver2, res)

	return res
}

func IsSyml(fi fs.FileInfo) bool {
	if fi != nil && fi.Mode() & os.ModeSymlink != 0 {
		return true
	} else {
		return false
	}
}

// func IsDir(p string) bool {
// 	fileInfo, err := os.Stat(p)
// 	if err != nil {
// 		return false
// 	} else if fileInfo.IsDir() {
// 		return true
// 	} else {
// 		return false
// 	}
// }

func PathExists(filename string) bool {
	if _, err := os.Stat(filename); os.IsNotExist(err) {
		return false
	} else {
		return true
	}
}

func CanWrite(path string) bool {
	err := syscall.Access(path, syscall.O_RDWR)
	if err != nil {
		return false
	} else {
		return true
	}
}

func stringInSlice(a string, list []string) bool {
    for _, b := range list {
        if b == a {
            return true
        }
    }
    return false
}

func pkgIsSpecified(a string, list []string) bool {
	for _, b := range list {
		if strings.HasPrefix(a, "node_modules/" + b) {
			return true
		}
	}
	return false
}


func countMatches(s string, re *regexp.Regexp) int {
    total := 0
    for start := 0; start < len(s); {
        remaining := s[start:] // slicing the string is cheap
        loc := re.FindStringIndex(remaining)
        if loc == nil {
            break
        }
        // loc[0] is the start index of the match,
        // loc[1] is the end index (exclusive)
        start += loc[1]
        total++
    }
    return total
}


func NodeModuleDirs(root string) ([]string, []string, error) {
	var scoped []string
	var standard []string
	nodeModP := regexp.MustCompile("node_modules")
	argsWithoutProg := os.Args[1:]

	err := godirwalk.Walk(root, &godirwalk.Options{
		Callback: func(walkPath string, dirent *godirwalk.Dirent) error {
			if walkPath == root {
				return nil
			}

			if strings.HasPrefix(walkPath, "node_modules/@") &&
				len(fwdSlash.FindAllStringIndex(walkPath, -1)) < 3 {
				return nil
			}

			if strings.Contains(walkPath, ".git") ||
				strings.Contains(walkPath, "/test/") ||
				strings.Contains(walkPath, ".bin") {
				return godirwalk.SkipThis
			}

			var scopedResult = scopedModuleRe.MatchString(walkPath)
			var stdModuleResult = stdModuleRe.MatchString(walkPath)

			if !pkgIsSpecified(walkPath, argsWithoutProg) {
				return godirwalk.SkipThis
			}

			if PathExists(path.Join(walkPath, "package.json")) &&
				countMatches(walkPath, nodeModP) > 1 &&
				!strings.HasSuffix(walkPath, "node_modules") {
				if scopedResult {
					scoped = append(scoped, walkPath)
				}

				if stdModuleResult {
					standard = append(standard, walkPath)
				}
			}
			return nil
		},
		FollowSymbolicLinks: true,
		Unsorted: false,
	})

	// sort.Slice(scoped, func(i, j int) bool {
	// 	return len(fwdSlash.FindAllStringIndex(scoped[i], -1)) >
	// 		len(fwdSlash.FindAllStringIndex(scoped[j], -1))
	// })

	// sort.Slice(standard, func(i, j int) bool {
	// 	return len(fwdSlash.FindAllStringIndex(standard[i], -1)) >
	// 		len(fwdSlash.FindAllStringIndex(standard[j], -1))
	// })

	return scoped, standard, err
}

type MovementTuple struct {
    target, src string
}


func main() {
	movement := make(map[string]string)

	if PathExists("node_modules") {
		var topLevelDeps []string
		topLevelDepsInfo, lsErr := ioutil.ReadDir("node_modules")

		if lsErr != nil {
			log.Fatal(lsErr)
		}

		for _, topFile := range topLevelDepsInfo {
			topLevelDeps = append(topLevelDeps, topFile.Name())
		}

		scoped, standard, _ := NodeModuleDirs("node_modules")

		for _, scopedFile := range scoped {
			dirName := path.Base(scopedFile)
			scopeName := path.Base(path.Dir(scopedFile))
			pName := path.Join(scopeName, dirName)
			os.MkdirAll(path.Join("./node_modules", scopeName), 0755)

			if _, err := os.Stat(path.Join("node_modules", pName)); err == nil {
				// path exists
			} else if os.IsNotExist(err) {
				// path does *not* exist
				target := path.Join("./node_modules", pName)
				_, ok := movement[target]


				if ok && len(fwdSlash.FindAllStringIndex(scopedFile, -1)) <=
					len(fwdSlash.FindAllStringIndex(movement[target], -1)) &&
					(semverCompare(scopedFile + "/package.json", movement[target] + "/package.json") > 0) {
					// higher semver, put the old one back from where it came from
					movement[target] = scopedFile
				} else if !ok {
					movement[target] = scopedFile
				}
			} else {
				// strangeness
				fmt.Println(err)
			}
		}


		for _, stdFile := range standard {
			dirName := path.Base(stdFile)
			if _, err := os.Stat(path.Join("./node_modules", dirName)); err == nil {
				// path exists
			} else if os.IsNotExist(err) {
				// path does *not* exist
				target := path.Join("./node_modules", dirName)
				_, ok := movement[target]

				if ok && len(fwdSlash.FindAllStringIndex(stdFile, -1)) <=
					len(fwdSlash.FindAllStringIndex(movement[target], -1)) &&
					(semverCompare(stdFile + "/package.json", movement[target] + "/package.json") > 0) {
					// higher semver, put the old one back from where it came from
					movement[target] = stdFile
				} else if !ok {
					movement[target] = stdFile
				}

			} else {
				// strangeness
				fmt.Println(err)
			}
		}

		var movementTarget []MovementTuple

		for src, target := range movement {
			tuple := MovementTuple{target, src}
			movementTarget = append(movementTarget, tuple)
		}

		sort.Slice(movementTarget, func(i, j int) bool {
			return len(fwdSlash.FindAllStringIndex(movementTarget[i].target, -1)) >
				len(fwdSlash.FindAllStringIndex(movementTarget[j].target, -1))
		})


		for _, tuple := range movementTarget {
			target := tuple.target
			src := tuple.src
			os.Chmod(target, 0755)
			err := os.Rename(target, src)

			if err != nil {
				copy.Copy(target, src, copy.Options{OnSymlink: func(string) copy.SymlinkAction { return copy.Deep }})
				os.Remove(target)
			}
		}

	} else {
		fmt.Println("no node_modules found for flattening")
	}
}
