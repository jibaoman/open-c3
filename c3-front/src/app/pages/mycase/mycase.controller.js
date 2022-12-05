(function() {
    'use strict';

    angular
        .module('openc3')
        .controller('MycaseController', MycaseController);

    function MycaseController($http, ngTableParams, $uibModal, genericService) {
        var vm = this;
        vm.seftime = genericService.seftime

        vm.edit = function (caseuuid,type,mt) {
            return;
            $http.post( '/api/agent/monitor/caseinfo/mycase', { uuid: caseuuid,type: type, mt: mt} ).success(function(data){
                if (data.stat){
                    vm.reload();
                }else {
                    swal({ title: '操作失败', text: data.info, type:'error' });
                }
            });
        };

        vm.reload = function () {
            vm.loadover = false;
            $http.get('/api/agent/monitor/caseinfo/mycase').success(function(data){
                if (data.stat){
                    vm.dataTable = new ngTableParams({count:25}, {counts:[],data:data.data});
                    vm.loadover = true;
                }else {
                    swal({ title:'获取列表失败', text: data.info, type:'error' });
                }
            });
        };
        vm.reload();
    }
})();