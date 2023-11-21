import { Contract, Provider, Signer, Wallet, utils } from 'zksync-web3';
import { Deployer } from '@matterlabs/hardhat-zksync-deploy';
import { bytecode as agentBytecode } from '../artifacts-zk/src/Agent.sol/Agent.json';
import * as ethers from 'ethers';
import { expect } from 'chai';
import * as hre from 'hardhat';
import { rightPad } from 'web3-utils';

const { constants, expectRevert, expectEvent } = require('@openzeppelin/test-helpers');

const abi = require('ethereumjs-abi');

const abiCoder = new ethers.utils.AbiCoder();

// https://github.com/matter-labs/local-setup/blob/main/rich-wallets.json
const RICH_WALLET_ADDR_0 = '0x36615Cf349d7F6344891B1e7CA7C72883F5dc049';
const RICH_WALLET_PK_0 = '0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110';
const RICH_WALLET_ADDR_1 = '0xa61464658AfeAf65CccaaFD3a512b69A83B77618';

const WRAPPED_NATIVE = '0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91';
const INIT_CURRENT_USER = '0x0000000000000000000000000000000000000001';

const DEPLOYER = RICH_WALLET_ADDR_0;
const PAUSER = RICH_WALLET_ADDR_0;

const ZERO_ADDRESS = constants.ZERO_ADDRESS;
const PAUSED = ZERO_ADDRESS;

async function deployRouter(deployer: Deployer, permit2): Promise<Contract> {
  const artifact = await deployer.loadArtifact('Router');
  const router = await deployer.deploy(artifact, [
    WRAPPED_NATIVE,
    permit2,
    DEPLOYER,
    utils.hashBytecode(agentBytecode),
  ]);
  const receipt = await router.setPauser(PAUSER, { from: DEPLOYER });
  await receipt.wait();
  return router;
}

async function deployMockPermit2(deployer: Deployer): Promise<Contract> {
  const artifact = await deployer.loadArtifact('MockPermit2');
  return await deployer.deploy(artifact, []);
}

async function deployMockERC20(deployer: Deployer): Promise<Contract> {
  const artifact = await deployer.loadArtifact('MockERC20');
  return await deployer.deploy(artifact, ['mockERC20', 'mock']);
}

describe('Router', function () {
  const logicsEmpty = [];
  const permit2DatasEmpty = [];

  const logicBatchEmpty = { logics: [], fees: [], referrals: [], deadline: 0 };
  const tokensReturnEmpty = [];

  let wallet;
  let provider;
  let router;
  let mockERC20;
  let mockPermit2;

  async function setUpTest() {
    provider = Provider.getDefaultProvider();
    wallet = new Wallet(RICH_WALLET_PK_0, provider);
    const deployer = new Deployer(hre, wallet);
    mockPermit2 = await deployMockPermit2(deployer);
    router = await deployRouter(deployer, mockPermit2.address);
    mockERC20 = await deployMockERC20(deployer);
  }

  before(async function () {});

  beforeEach(async function () {});

  afterEach(async function () {});

  describe('Normal', function () {
    beforeEach(async function () {
      await setUpTest();
    });

    it('setup', async function () {
      expect((await router.agentImplementation()) != ZERO_ADDRESS);
      expect((await router.currentUser()) == INIT_CURRENT_USER);
      expect((await router.owner()) == DEPLOYER);
      expect((await router.pauser()) == PAUSER);
    });

    it('new agent', async function () {
      // use sendTransaction here due to error msg: newAgent is not a function
      const calldata = abi.simpleEncode('newAgent()');
      const receipt = await wallet.sendTransaction({ to: router.address, data: calldata });
      await receipt.wait();

      const salt = rightPad(wallet.address.toString(), 64, '0'); // Turn wallet address to bytes32
      const inputBytecode = abiCoder.encode(['address'], [await router.agentImplementation()]);
      const newAgentAddr = utils.create2Address(router.address, utils.hashBytecode(agentBytecode), salt, inputBytecode);
      // TODO: expect returned new agent address is the same as the returned address from router.getAgent
      expect(await router.getAgent(wallet.address)).to.be.eq(newAgentAddr);
    });

    it('new agent for user', async function () {
      const user = wallet.address;
      const calcAgent = await router.calcAgent(user);
      // use sendTransaction here due to error msg: newAgent is not a function
      const calldata = abi.simpleEncode('newAgent(address)', user);
      const receipt = await wallet.sendTransaction({ to: router.address, data: calldata });
      await receipt.wait();
      expect(await router.getAgent(user)).to.be.eq(calcAgent);
    });

    it('calc agent', async function () {
      const predictAddress = await router.calcAgent(wallet.address);
      const calldata = abi.simpleEncode('newAgent()');
      const receipt = await wallet.sendTransaction({ to: router.address, data: calldata });
      await receipt.wait();
      expect(await router.getAgent(wallet.address)).to.be.eq(predictAddress);
    });

    it('new user execute', async function () {
      const user = wallet.address;
      expect(await router.getAgent(user)).to.be.eq(ZERO_ADDRESS);

      const receipt = await router.execute(permit2DatasEmpty, logicsEmpty, tokensReturnEmpty, {
        from: user,
      });

      await receipt.wait();
      expect(await router.getAgent(user)).to.be.not.eq(ZERO_ADDRESS);
    });

    it('old user execute', async function () {
      const user = wallet.address;
      const calldata = abi.simpleEncode('newAgent()');
      const receiptNewAgent = await wallet.sendTransaction({ to: router.address, data: calldata });
      await receiptNewAgent.wait();
      expect(await router.getAgent(user)).to.be.not.eq(ZERO_ADDRESS);

      const receiptExecute = await router.execute(permit2DatasEmpty, logicsEmpty, tokensReturnEmpty, {
        from: user,
      });
      await receiptExecute.wait();
    });

    it('get agent with user executing', async function () {
      const user = wallet.address;
      const calldata = abi.simpleEncode('newAgent()');
      const receiptNewAgent = await wallet.sendTransaction({ to: router.address, data: calldata });
      await receiptNewAgent.wait();
      const receiptExecute = await router.execute(permit2DatasEmpty, logicsEmpty, tokensReturnEmpty, {
        from: user,
      });
      await receiptExecute.wait();
      const [, agentAddress] = await router.getCurrentUserAgent();
      expect(agentAddress).to.be.eq(ZERO_ADDRESS);
    });

    it.skip('execute by sig', async function () {});

    it('add signer', async function () {
      const newSigner = RICH_WALLET_ADDR_1;
      const receipt = await router.addSigner(newSigner);
      await receipt.wait();
      expect(await router.signers(newSigner)).to.be.true;
      // TODO: Verify event
      // await expectEvent.inTransaction(receipt.tx, router, 'SignerAdded', {
      //   signer: newFeeCollector,
      // });
      // expectEvent(receipt, 'SignerAdded', {
      //   signer: newSigner,
      // });
    });

    it('remove signer', async function () {
      const newSigner = RICH_WALLET_ADDR_1;
      const receiptAdd = await router.addSigner(newSigner);
      await receiptAdd.wait();
      expect(await router.signers(newSigner)).to.be.true;

      const receiptRemove = await router.removeSigner(newSigner);
      await receiptRemove.wait();
      expect(await router.signers(newSigner)).to.be.false;
      // TODO: Verify event
    });

    // TODO: how to exec with sig
    it.skip('execute with signer fee', async function () {
      const signer = provider.getSigner(wallet.address);
    });

    it.skip('execute by sig with signer fee', async function () {});

    it('set pauser', async function () {
      const newPauser = RICH_WALLET_ADDR_1;
      const receipt = await router.setPauser(newPauser);
      await receipt.wait();
      expect(await router.pauser()).to.be.eq(newPauser);
      // TODO: Verify event
    });

    it('pause', async function () {
      const receipt = await router.pause({ from: PAUSER });
      await receipt.wait();
      expect(await router.currentUser()).to.be.eq(PAUSED);
    });

    it('unpause', async function () {
      // Pause
      const receiptPause = await router.pause({ from: PAUSER });
      await receiptPause.wait();

      // Unpause
      const receiptUnpause = await router.unpause({ from: PAUSER });
      await receiptUnpause.wait();
      expect(await router.currentUser()).to.be.eq(INIT_CURRENT_USER);
    });

    it('rescue', async function () {
      // Mint token
      const amount = 1;
      const receiptMint = await mockERC20.mint(router.address, amount);
      await receiptMint.wait();

      // Rescue
      const receiver = RICH_WALLET_ADDR_1;
      const receiptRescue = await router.rescue(mockERC20.address, receiver, amount, { from: DEPLOYER });
      await receiptRescue.wait();
      expect((await mockERC20.balanceOf(router.address)).toString()).to.be.eq('0');
      expect((await mockERC20.balanceOf(receiver)).toString()).to.be.eq(amount.toString());
    });

    it('set fee collector', async function () {
      const newFeeCollector = RICH_WALLET_ADDR_1;
      const receipt = await router.setFeeCollector(newFeeCollector, { from: DEPLOYER });
      await receipt.wait();
      expect(await router.defaultCollector()).to.be.eq(newFeeCollector);
      // TODO: Verify event
      // await expectEvent.inTransaction(receipt.tx, router, 'FeeCollectorSet', {
      //   feeCollector_: newFeeCollector,
      // });
    });

    it.skip('allow by user', async function () {});
    it.skip('allow by sig', async function () {});
    it.skip('disallow', async function () {});
    it.skip('invalidate delegation nonces', async function () {});
    it.skip('execute for', async function () {});
    it.skip('execute for with signer fee', async function () {});
    it.skip('invalidate execution nonces', async function () {});

    it('should revert: new agent again', async function () {
      // New agent
      const calldata = abi.simpleEncode('newAgent()');
      const receiptFirst = await wallet.sendTransaction({ to: router.address, data: calldata });
      await receiptFirst.wait();

      // New agent again
      await expectRevert.unspecified(wallet.sendTransaction({ to: router.address, data: calldata }));
    });

    it.skip('should revert: execute by sig with incorrcet signature', async function () {});

    it('should revert: add signer by non owner', async function () {
      const newSigner = RICH_WALLET_ADDR_1;
      await expectRevert(
        router.addSigner(newSigner, { from: newSigner }),
        'Contract with a Signer cannot override from (operation="overrides.from", code=UNSUPPORTED_OPERATION, version=contracts/5.7.0'
      );
    });

    it('should revert: remove signer by non owner', async function () {
      const signer = RICH_WALLET_ADDR_1;
      await expectRevert(
        router.removeSigner(signer, { from: signer }),
        'Contract with a Signer cannot override from (operation="overrides.from", code=UNSUPPORTED_OPERATION, version=contracts/5.7.0'
      );
    });

    it('should revert: execute when paused', async function () {
      const receiptPause = await router.pause({ from: PAUSER });
      await receiptPause.wait();

      const user = wallet.address;
      await expectRevert.unspecified(
        router.execute(permit2DatasEmpty, logicsEmpty, tokensReturnEmpty, {
          from: user,
        })
      );

      const signer = wallet.address;
      await expectRevert.unspecified(
        router.executeWithSignerFee(
          permit2DatasEmpty,
          logicBatchEmpty,
          signer,
          abiCoder.encode(['bytes'], ['0x']),
          tokensReturnEmpty,
          {
            from: user,
          }
        )
      );
    });

    // TODO: call exec sig
    it.skip('should revert: execute reentrance', async function () {
      // const logic0 = {
      //   to: router.address,
      //   data: abi.simpleEncode('execute(bytes)'),
      //   inputs: inputsEmpty,
      //   wrapMode: WRAP_MODE_NONE,
      //   approveTo: ZERO_ADDRESS,
      //   callback: ZERO_ADDRESS,
      // };
      // const user = wallet.address;
      // const calldata = abi.simpleEncode('newAgent()');
      // const receiptNewAgent = await wallet.sendTransaction({ to: router.address, data: calldata });
      // await receiptNewAgent.wait();
      // expect(await router.getAgent(user)).to.be.not.eq(ZERO_ADDRESS);
      // const logics = [logic0];
      // const receiptExecute = await router.execute(logics, tokensReturnEmpty, SIGNER_REFERRAL, {
      //   from: user,
      // });
      // await receiptExecute.wait();
    });

    // TODO: exec
    it.skip('should revert: execute signature expired', async function () {});

    it('should revert: invalid signer', async function () {});
    it('should revert: execute with invalid signature', async function () {});
    it('should revert: execute by sig with signer fee with incorrect user signature', async function () {});

    it('should revert: set pauser by non owner', async function () {
      const newPauser = RICH_WALLET_ADDR_1;
      await expectRevert(
        router.setPauser(newPauser, { from: newPauser }),
        'Contract with a Signer cannot override from (operation="overrides.from", code=UNSUPPORTED_OPERATION, version=contracts/5.7.0'
      );
    });

    it('should revert: set invalid new pauser', async function () {
      const invalidPauser = ZERO_ADDRESS;
      // unsepecified here because error msg includes deployment info (eg. deployed router address)
      await expectRevert.unspecified(router.setPauser(invalidPauser, { from: DEPLOYER }));
    });

    it('should revert: pause by non pauser', async function () {
      const invalidPauser = Wallet.createRandom();
      await expectRevert.unspecified(router.connect(invalidPauser.address).pause());
    });

    it('should revert: pause when already paused', async function () {
      // Pause
      const receipt = await router.pause({ from: PAUSER });
      await receipt.wait();

      // Pause again
      // unsepecified here because error msg includes deployment info (eg. deployed router address)
      await expectRevert.unspecified(router.pause({ from: PAUSER }));
    });

    it('should revert: unpause by non pauser', async function () {
      const nonPauser = Wallet.createRandom();
      await expectRevert.unspecified(router.connect(nonPauser.address).unpause());
    });

    it('should revert: unpause when not paused', async function () {
      // unsepecified here because error msg includes deployment info (eg. deployed router address)
      await expectRevert.unspecified(router.unpause({ from: PAUSER }));
    });

    it('should revert: rescue by non owner', async function () {
      // Mint token
      const amount = 1;
      const receiptMint = await mockERC20.mint(router.address, amount);
      await receiptMint.wait();

      // Rescue
      const receiver = RICH_WALLET_ADDR_1;
      const nonOwner = RICH_WALLET_ADDR_1;
      await expectRevert(
        router.rescue(mockERC20.address, receiver, amount, { from: nonOwner }),
        'Contract with a Signer cannot override from (operation="overrides.from", code=UNSUPPORTED_OPERATION, version=contracts/5.7.0)'
      );
    });

    it('should revert: receive native token', async function () {
      const amount = 1;
      // unsepecified here because error msg includes deployment info (eg. deployed router address)
      await expectRevert.unspecified(wallet.sendTransaction({ to: router.address, value: amount }));
    });

    it('should revert: set fee collector by non owner', async function () {
      const newFeeCollector = RICH_WALLET_ADDR_1;
      const nonOwner = RICH_WALLET_ADDR_1;
      await expectRevert(
        router.setFeeCollector(newFeeCollector, { from: nonOwner }),
        'Contract with a Signer cannot override from (operation="overrides.from", code=UNSUPPORTED_OPERATION, version=contracts/5.7.0)'
      );
    });

    it('should revert: set invalid fee collector', async function () {
      const invalidFeeCollector = ZERO_ADDRESS;
      await expectRevert.unspecified(router.setFeeCollector(invalidFeeCollector, { from: DEPLOYER }));
    });

    it('should revert: allow by sig with incorrect nonce', async function () {});
    it('should revert: invalidate excessive delegation nonces', async function () {});
    it('should revert: execute for after expiry', async function () {});
    it('should revert: execute for with signer fee after expiry', async function () {});
    it('should revert: invalidate excessive execution nonces', async function () {});
    it('should revert: invalidate old execution nonce', async function () {});
  });
});
