package main

import "fmt"
import "io"
import "io/ioutil"
import "io/fs"
import "log"
import "os"
import "path"
import "regexp"
import "strings"
import "syscall"
import "github.com/goccy/go-json"
import "github.com/blang/semver"
import "github.com/karrick/godirwalk"

var scopedModuleRe,_ = regexp.Compile(`node_modules/@([^/])*/([^/])*$`)
var stdModuleRe,_ = regexp.Compile(`node_modules/[^@^/]*$`)

func semverFits(pkgJson1 string, pkgJson2 string) int {
	pkgJsonBytes1, err1 := ioutil.ReadFile(pkgJson1)

	if err1 != nil {
		fmt.Print(err1)
	}

	pkgJsonBytes2, err2 := ioutil.ReadFile(pkgJson2)

	if err2 != nil {
		fmt.Print(err2)
	}

	type PackageJson struct {
		version string
	}

	dec1 := json.NewDecoder(strings.NewReader(string(pkgJsonBytes1)))
	var ver1 = "0.0.0"
	for {
		var pkg1 PackageJson
		if err := dec1.Decode(&pkg1); err == io.EOF {
			break
		} else if err != nil {
			log.Fatal(err)
		}

		ver1 = pkg1.version
	}

	dec2 := json.NewDecoder(strings.NewReader(string(pkgJsonBytes2)))
	var ver2 = "0.0.0"
	for {
		var pkg2 PackageJson
		if err := dec2.Decode(&pkg2); err == io.EOF {
			break
		} else if err != nil {
			log.Fatal(err)
		}

		ver2 = pkg2.version
	}

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
		Callback: func(walkPath string, de *godirwalk.Dirent) error {
			if strings.Contains(walkPath, ".git") || strings.Contains(walkPath, ".bin") {
				return godirwalk.SkipThis
			}
			var scopedResult = scopedModuleRe.MatchString(walkPath)
			var stdModuleResult = stdModuleRe.MatchString(walkPath)
			if !pkgIsSpecified(walkPath, argsWithoutProg) ||
				(!scopedResult && !stdModuleResult && !strings.HasSuffix(walkPath, "node_modules")) {
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
		Unsorted: true,
	})

	return scoped, standard, err
}


func main() {

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

		for _, stdFile := range standard {
			dirName := path.Base(stdFile)
			if _, err := os.Stat(path.Join("./node_modules", dirName)); err == nil {
				// path exists

			} else if os.IsNotExist(err) {
				// path does *not* exist
				os.Rename(stdFile, path.Join("./node_modules", dirName))

			} else {
				// strangeness
				fmt.Println(err)
			}

		}

		for _, scopedFile := range scoped {
			dirName := path.Base(scopedFile)
			scopeName := path.Base(path.Dir(scopedFile))
			pName := path.Join(scopeName, dirName)
			os.MkdirAll(path.Join("./node_modules", scopeName), 0755)
			if _, err := os.Stat(path.Join("./node_modules", pName)); err == nil {
				// path exists
			} else if os.IsNotExist(err) {
				// path does *not* exist
				os.Rename(scopedFile, path.Join("./node_modules", pName))
			} else {
				// strangeness
				fmt.Println(err)
			}
		}

	} else {
		fmt.Println("no node_modules found for flattening")
	}
}
