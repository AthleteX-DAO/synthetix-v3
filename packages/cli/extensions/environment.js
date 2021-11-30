const { extendEnvironment } = require('hardhat/config');

extendEnvironment((hre) => {
  if (hre.cli) {
    throw new Error('Cli plugin already loaded.');
  }

  hre.cli = {
    contract: null,
  };

  // Prevent any properties being added to hre.cli
  // other than those defined above.
  Object.preventExtensions(hre.cli);
  Object.preventExtensions(hre.cli.contract);
});
