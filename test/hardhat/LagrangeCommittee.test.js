const { expect } = require("chai");
const { ethers } = require("hardhat");
const { poseidon } = require('circomlib');
const bls = require('@noble/bls12-381');
const shared = require("./shared");

const poseidonUnit = require("circomlibjs").poseidonContract;

const sponge = 0;

const deployPoseidon = async (signerNode) => {
    const poseidonAddrs = {};
    const params = [1, 2, 3, 4, 5, 6];
    await Promise.all(params.map(async i => {
        let poseidonCode = null;
        let poseidonABI = null;
        try {
            if (sponge) {
                poseidonCode = await poseidonUnit.createCode("mimcsponge", 220);
                poseidonABI = await poseidonUnit.abi;
            } else {
                poseidonCode = await poseidonUnit.createCode(i);
                poseidonABI = await poseidonUnit.generateABI(i);
            }
        } catch (err) {
            console.log(err);
        }

        const cf = new ethers.ContractFactory(
            poseidonABI,
            poseidonCode,
            signerNode
        );
        const cd = await cf.deploy();
        if (i == 2) {
            const res = await cd["poseidon(uint256[2])"]([1, 2]);
            const resString = res.toString();
            const target = String("7853200120776062878684798364095072458815029376092732009249414926327459813530");
            console.log("Result:", resString);
            console.log("Expected:", target);
            console.log("Hash check:", resString == target);
        }
        await cd.deployed();
        poseidonAddrs[i] = cd.address;
    }));

    return poseidonAddrs;
}

const serveUntilBlock = 4294967295;
const operators = require("../../config/operators.json");
const stake = 100000000;

describe("LagrangeCommittee", function () {
    let admin, proxy, poseidonAddresses;

    before(async function () {
        [admin] = await ethers.getSigners();
        poseidonAddresses = await deployPoseidon(admin);
    });

    beforeEach(async function () {
        const LagrangeCommitteeFactory = await ethers.getContractFactory("LagrangeCommittee");
        const committee = await LagrangeCommitteeFactory.deploy(admin.address);
        await committee.deployed();

        console.log("Deploying empty contract...");

        const EmptyContractFactory = await ethers.getContractFactory("EmptyContract");
        const emptyContract = await EmptyContractFactory.deploy();
        await emptyContract.deployed();

        console.log("Deploying proxy...");

        const ProxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
        const proxyAdmin = await ProxyAdminFactory.deploy();
        await proxyAdmin.deployed();

        console.log("Deploying transparent proxy...");

        const TransparentUpgradeableProxyFactory = await ethers.getContractFactory("TransparentUpgradeableProxy");
        proxy = await TransparentUpgradeableProxyFactory.deploy(emptyContract.address, proxyAdmin.address, "0x");
        await proxy.deployed();

        console.log("Upgrading proxy...");

        await proxyAdmin.upgradeAndCall(
            proxy.address,
            committee.address,
            committee.interface.encodeFunctionData("initialize", [admin.address, poseidonAddresses[1], poseidonAddresses[2], poseidonAddresses[3], poseidonAddresses[4], poseidonAddresses[5], poseidonAddresses[6]])
        )
        
        shared.LagrangeCommittee = committee;
    });

    it("leaf hash", async function () {
        const committee = await ethers.getContractAt("LagrangeCommittee", proxy.address, admin)
        const pubKey = bls.PointG1.fromHex(operators[0].bls_pub_keys[0].slice(2));
        const Gx = pubKey.toAffine()[0].value.toString(16).padStart(96, '0');
        const Gy = pubKey.toAffine()[1].value.toString(16).padStart(96, '0');
        const newPubKey = "0x" + Gx + Gy;
        const address = operators[0].operators[0];
        await committee.addOperator(address, operators[0].chain_id, newPubKey, stake, serveUntilBlock);
        await committee.registerChain(operators[0].chain_id, 10000, 1000);

        const chunks = [];
        for (let i = 0; i < 4; i++) {
            chunks.push(BigInt("0x" + Gx.slice(i * 24, (i + 1) * 24)));
        }
        
        for (let i = 0; i < 4; i++) {
            chunks.push(BigInt("0x" + Gy.slice(i * 24, (i + 1) * 24)));
        }
        const stakeStr = stake.toString(16).padStart(32, '0');
        chunks.push(BigInt(address.slice(0, 26)));
        chunks.push(BigInt("0x" + address.slice(26, 42) + stakeStr.slice(0, 8)));
        chunks.push(BigInt("0x" + stakeStr.slice(8, 32)));
        
        const left = poseidon(chunks.slice(0, 6));
        const right = poseidon(chunks.slice(6, 11));
        const leaf = poseidon([left, right]);
        console.log(chunks.map((e) => { return e.toString(16);}), leaf.toString(16));

        const leafHash = await committee.CommitteeLeaves(operators[0].chain_id, 0);
        const committeeRoot = await committee.getCommittee(operators[0].chain_id, 1000);
        const op = await committee.operators(operators[0].operators[0]);
        console.log(op);
        console.log(leafHash);
        expect(leafHash).to.equal(committeeRoot.currentCommittee.root);
        expect(stake).to.equal(committeeRoot.currentCommittee.totalVotingPower.toNumber());
        expect(leaf).to.equal(leafHash);
    });

    it("merkle root", async function () {
        const committee = await ethers.getContractAt("LagrangeCommittee", proxy.address, admin);
        for (let i = 0; i < operators[0].operators.length; i++) {
            const op = operators[0].operators[i];
            const pubKey = bls.PointG1.fromHex(operators[0].bls_pub_keys[i].slice(2));
            const Gx = pubKey.toAffine()[0].value.toString(16).padStart(96, '0');
            const Gy = pubKey.toAffine()[1].value.toString(16).padStart(96, '0');
            const newPubKey = "0x" + Gx + Gy;

            await committee.addOperator(op, operators[0].chain_id,
                newPubKey, stake, serveUntilBlock);
        }
        await committee.registerChain(operators[0].chain_id, 10000, 1000);

        const leaves = await Promise.all(operators[0].operators.map(async (op, index) => {
            const leaf = await committee.CommitteeLeaves(operators[0].chain_id, index);
            return BigInt(leaf.toHexString());
        }));
        const committeeRoot = await committee.getCommittee(operators[0].chain_id, 1000);
        console.log("leaves: ", leaves.map(l => l.toString(16)));
        console.log("current root: ", committeeRoot.currentCommittee.root.toHexString());
        console.log("next root: ", committeeRoot.nextRoot.toHexString());

        let count = 1;
        while (count < leaves.length) {
            count *= 2;
        }
        const len = leaves.length;
        for (let i = 0; i < count - len; i++) {
            leaves.push(BigInt(0));
        }

        while (count > 1) {
            for (let i = 0; i < count; i += 2) {
                const left = leaves[i];
                const right = leaves[i + 1];
                console.log("left: ", left, "right: ", right);
                const hash = poseidon([left, right]);
                console.log("hash: ", hash);
                leaves[i / 2] = hash;
            }
            count /= 2;
        }
        console.log(leaves[0].toString(16));
        expect("0x" + leaves[0].toString(16)).to.equal(committeeRoot.currentCommittee.root.toHexString());
    });
});