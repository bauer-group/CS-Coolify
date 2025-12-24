## [0.10.3](https://github.com/bauer-group/DC-Coolify/compare/v0.10.2...v0.10.3) (2025-12-24)


### Bug Fixes

* enhance user management and password generation in cloud-init configuration ([2655199](https://github.com/bauer-group/DC-Coolify/commit/265519998559996006c428a1a734c4a97c88d38c))
* update user configuration and password generation in cloud-init ([6a13ddc](https://github.com/bauer-group/DC-Coolify/commit/6a13ddc1a100c90d8c9e03b06c8cb615f1141e95))

## [0.10.2](https://github.com/bauer-group/DC-Coolify/compare/v0.10.1...v0.10.2) (2025-12-24)


### Bug Fixes

* standardize description casing and refactor job definitions in release workflow ([57fd1bb](https://github.com/bauer-group/DC-Coolify/commit/57fd1bb8f9196d95a0e0fe25db923c5fee121260))
* update hostname to include domain in cloud-init configuration ([58da837](https://github.com/bauer-group/DC-Coolify/commit/58da837670bfd211f7fb17aafa77612cf1233dc1))
* update timezone to UTC and refine Git repository configuration in cloud-init ([f3d6d5a](https://github.com/bauer-group/DC-Coolify/commit/f3d6d5ac9966094dda9487cc5570f60134a9fb5e))

## [0.10.1](https://github.com/bauer-group/DC-Coolify/compare/v0.10.0...v0.10.1) (2025-12-22)


### Bug Fixes

* update SOCKETI_VERSION to latest in docker-compose and setup script for consistency ([217882e](https://github.com/bauer-group/DC-Coolify/commit/217882ecc3944656bf0d1c4b45f6f8a9f3dedcaf))
* update TIMEZONE to UTC in configuration files for consistency ([1c48382](https://github.com/bauer-group/DC-Coolify/commit/1c483825f80d722f9975c0c76f19b593b446c000))

# [0.10.0](https://github.com/bauer-group/DC-Coolify/compare/v0.9.0...v0.10.0) (2025-12-22)


### Features

* add PUSHER_HOST and PUSHER_PORT configuration options and update setup script for improved WebSocket support ([1cc38ec](https://github.com/bauer-group/DC-Coolify/commit/1cc38eceae8825b2ea2a6890ff584d271bff05ba))

# [0.9.0](https://github.com/bauer-group/DC-Coolify/compare/v0.8.12...v0.9.0) (2025-12-22)


### Features

* add configurable PUSHER_HOST and PUSHER_PORT for improved setup flexibility ([8b691c5](https://github.com/bauer-group/DC-Coolify/commit/8b691c59b9a65c81014f499b9be828e2d4285d03))

## [0.8.12](https://github.com/bauer-group/DC-Coolify/compare/v0.8.11...v0.8.12) (2025-12-22)


### Bug Fixes

* update soketi-server references to coolify-realtime in scripts and configuration ([c98f58c](https://github.com/bauer-group/DC-Coolify/commit/c98f58c83959e555952e73b40662e201c746499e))

## [0.8.11](https://github.com/bauer-group/DC-Coolify/compare/v0.8.10...v0.8.11) (2025-12-22)


### Bug Fixes

* update PHP-FPM server settings to improve performance ([1cee800](https://github.com/bauer-group/DC-Coolify/commit/1cee800f155698406fa01786d9c99e6d700e3641))

## [0.8.10](https://github.com/bauer-group/DC-Coolify/compare/v0.8.9...v0.8.10) (2025-12-22)


### Bug Fixes

* rename soketi-server to coolify-realtime and update port exposure in docker-compose.yml ([d30ec10](https://github.com/bauer-group/DC-Coolify/commit/d30ec10662820f41ba300b35b664ccdd572362b4))

## [0.8.9](https://github.com/bauer-group/DC-Coolify/compare/v0.8.8...v0.8.9) (2025-12-22)


### Bug Fixes

* standardize network name to lowercase in docker-compose.yml ([b5ab303](https://github.com/bauer-group/DC-Coolify/commit/b5ab3035c966391b6b02ba9097fa64b0a4131fa3))

## [0.8.8](https://github.com/bauer-group/DC-Coolify/compare/v0.8.7...v0.8.8) (2025-12-22)


### Bug Fixes

* rename coolify-application container to coolify for consistency ([1bf9f1e](https://github.com/bauer-group/DC-Coolify/commit/1bf9f1e6eadef454933313ddf135d83193367cd8))

## [0.8.7](https://github.com/bauer-group/DC-Coolify/compare/v0.8.6...v0.8.7) (2025-12-22)


### Bug Fixes

* add additional DNS nameservers for improved network resolution ([24c9282](https://github.com/bauer-group/DC-Coolify/commit/24c9282e54e6f839ba83da5069e72b9a09853ea1))
* update Soketi port numbers and standardize container names in README ([0bb830a](https://github.com/bauer-group/DC-Coolify/commit/0bb830a89bcf096047eb8e32d1c69fecbb344ca0))

## [0.8.6](https://github.com/bauer-group/DC-Coolify/compare/v0.8.5...v0.8.6) (2025-12-22)


### Bug Fixes

* improve variable declaration and shellcheck compliance in scripts ([a3ab7c1](https://github.com/bauer-group/DC-Coolify/commit/a3ab7c1ce597f22a984921c5962c8fa6ad14a7d1))

## [0.8.5](https://github.com/bauer-group/DC-Coolify/compare/v0.8.4...v0.8.5) (2025-12-22)


### Bug Fixes

* update network configurations for Docker with new IPv4 and IPv6 ranges ([a33c0e3](https://github.com/bauer-group/DC-Coolify/commit/a33c0e3f3d67f862e7ef7c6166c9e025a8d762bd))

## [0.8.4](https://github.com/bauer-group/DC-Coolify/compare/v0.8.3...v0.8.4) (2025-12-21)


### Bug Fixes

* standardize container names in docker-compose.yml to lowercase ([eba6177](https://github.com/bauer-group/DC-Coolify/commit/eba617723d847d739a04cc0367230e3285e1b182))
* update container names in coolify.sh to lowercase ([fb5810e](https://github.com/bauer-group/DC-Coolify/commit/fb5810e7578b697ae23a7a4f681346c7b2e063b0))
* update default application port from 6000 to 8000 in coolify.sh and README.md ([6abee7b](https://github.com/bauer-group/DC-Coolify/commit/6abee7bdf31a6f1750d1850c8a14860579708025))

## [0.8.3](https://github.com/bauer-group/DC-Coolify/compare/v0.8.2...v0.8.3) (2025-12-20)


### Bug Fixes

* update watchtower image and enhance root password generation in setup script ([00ac6c1](https://github.com/bauer-group/DC-Coolify/commit/00ac6c1fd95a64645dc45537c69913c6e5f22635))

## [0.8.2](https://github.com/bauer-group/DC-Coolify/compare/v0.8.1...v0.8.2) (2025-12-20)


### Bug Fixes

* update docker-compose and setup scripts to use environment variables for port configuration and enhance root password generation ([01f15dd](https://github.com/bauer-group/DC-Coolify/commit/01f15dd9fa4b3620907b62c6efd3d6c264ca7303))

## [0.8.1](https://github.com/bauer-group/DC-Coolify/compare/v0.8.0...v0.8.1) (2025-12-20)


### Bug Fixes

* update .gitattributes and update.sh to handle file permissions correctly ([f5602bd](https://github.com/bauer-group/DC-Coolify/commit/f5602bdbb3ad6ca6038f422fa34d99646997a56d))

# [0.8.0](https://github.com/bauer-group/DC-Coolify/compare/v0.7.0...v0.8.0) (2025-12-20)


### Bug Fixes

* update watchtower image reference to remove ghcr.io prefix ([43ae173](https://github.com/bauer-group/DC-Coolify/commit/43ae1738d5372c8e917bf2ca5d741894e5628e8c))


### Features

* add update script for seamless repository updates ([cb99fec](https://github.com/bauer-group/DC-Coolify/commit/cb99fecdfe1baaa6a51d9f7c1ffc8862d7108d55))
* update setup script for improved functionality ([543c716](https://github.com/bauer-group/DC-Coolify/commit/543c7165832de85c6a487dfc258e12cd3cd24ab3))

# [0.7.0](https://github.com/bauer-group/DC-Coolify/compare/v0.6.0...v0.7.0) (2025-12-20)


### Features

* update install and setup scripts for improved functionality ([56eb9fe](https://github.com/bauer-group/DC-Coolify/commit/56eb9feff007cc24ddbc51756d41a127f2faa9e6))
* update README and add install script for one-line installation options ([6954a20](https://github.com/bauer-group/DC-Coolify/commit/6954a20e0ba16a65af65971b21c0c13871676b57))

# [0.6.0](https://github.com/bauer-group/DC-Coolify/compare/v0.5.0...v0.6.0) (2025-12-20)


### Features

* update .gitattributes to ignore permission changes for shell scripts ([e94b370](https://github.com/bauer-group/DC-Coolify/commit/e94b3709ce0f2773bf2253b9e6f5909e682120ea))

# [0.5.0](https://github.com/bauer-group/DC-Coolify/compare/v0.4.0...v0.5.0) (2025-12-20)


### Features

* add .gitattributes file to manage line endings and binary files ([c907229](https://github.com/bauer-group/DC-Coolify/commit/c907229d56bef0a2d73481cd953c3407a186ccbe))
* update watchtower image reference to use ghcr.io in README and docker-compose ([5c0d5e6](https://github.com/bauer-group/DC-Coolify/commit/5c0d5e682dc66b06e20fdce55bdcf862d81ce40c))

# [0.4.0](https://github.com/bauer-group/DC-Coolify/compare/v0.3.0...v0.4.0) (2025-12-20)


### Features

* add --wait option to stack management commands for improved startup handling ([185bbd0](https://github.com/bauer-group/DC-Coolify/commit/185bbd0eb81f18b5ea32e823b0844da7c13a01d2))
* update application ports from 6000 to 8000 in README, docker-compose, and setup script ([05dc73b](https://github.com/bauer-group/DC-Coolify/commit/05dc73bfb767f1a87fbaa9185edc08eee62e298f))

# [0.3.0](https://github.com/bauer-group/DC-Coolify/compare/v0.2.0...v0.3.0) (2025-12-20)


### Features

* update README with improved setup instructions and add stack update guidelines ([a02a2cb](https://github.com/bauer-group/DC-Coolify/commit/a02a2cba757920fc86a01ddc4b9fc42bea58c8d0))

# [0.2.0](https://github.com/bauer-group/DC-Coolify/compare/v0.1.0...v0.2.0) (2025-12-20)


### Features

* enhance do_destroy function to provide clearer warnings and remove additional resources ([0b4c682](https://github.com/bauer-group/DC-Coolify/commit/0b4c68242dd09740faefc77d100ebd61d5c58335))

# [0.1.0](https://github.com/bauer-group/DC-Coolify/compare/v0.0.0...v0.1.0) (2025-12-20)


### Features

* enhance setup script by adding missing sentinel folder and updating random value generation for .env file ([647749c](https://github.com/bauer-group/DC-Coolify/commit/647749c1cb9be9de855e46de5357cc6cf1a21771))
* update setup script to include file copying and enhance folder structure creation ([a225a71](https://github.com/bauer-group/DC-Coolify/commit/a225a714868d13e86b1cca01680718298b492090))

# 1.0.0 (2025-12-20)


### Bug Fixes

* update copyright year in LICENSE file ([d05b797](https://github.com/bauer-group/DC-Coolify/commit/d05b79722c75c754247b88ba940ab3b888585266))


### Features

* enhance backup process and improve Docker network configuration ([a16c10b](https://github.com/bauer-group/DC-Coolify/commit/a16c10ba0dea9adbedad0883089a56a334f31e02))
